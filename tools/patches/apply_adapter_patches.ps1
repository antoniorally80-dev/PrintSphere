# Apply local timeout-safe patches to managed_components/espressif__esp_lvgl_adapter.
#
# Background: vanilla esp_lvgl_adapter 0.4.x uses portMAX_DELAY in two
# critical TE-sync paths. If the TE GPIO signal is missed (panel quirk,
# brightness=0, DMA stall under camera+TLS load) the LVGL worker task
# blocks indefinitely and starves every esp_lv_adapter_lock() caller --
# the UI freezes silently after 5..30 minutes of runtime.
#
# This script bounds those waits so the worker can recover by signalling
# flush_ready and returning the LVGL mutex. Runs are idempotent: if the
# files already contain the patch markers nothing is changed.
#
# Usage (after `idf.py fullclean` or first checkout):
#   powershell -ExecutionPolicy Bypass -File tools/patches/apply_adapter_patches.ps1
#
# Tested against: espressif/esp_lvgl_adapter 0.4.2.

param(
    [string]$AdapterRoot = "managed_components/espressif__esp_lvgl_adapter"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $AdapterRoot)) {
    Write-Host "[adapter-patch] adapter not present at $AdapterRoot -- skipping (run `idf.py reconfigure` first)."
    exit 0
}

function Apply-Patch {
    param(
        [string]$Path,
        [string]$Marker,
        [string]$Find,
        [string]$Replace,
        [string]$Label
    )
    if (-not (Test-Path $Path)) {
        Write-Warning ("[adapter-patch] missing file: {0} -- adapter version mismatch?" -f $Path)
        exit 1
    }
    $text = Get-Content $Path -Raw
    if ($text.Contains($Marker)) {
        Write-Host ("[adapter-patch] {0} : already applied." -f $Label)
        return
    }
    if (-not $text.Contains($Find)) {
        Write-Warning ("[adapter-patch] {0} : upstream source does not match expected pattern. Adapter version may have changed; review the patch script." -f $Label)
        exit 1
    }
    $patched = $text.Replace($Find, $Replace)
    Set-Content -Path $Path -Value $patched -NoNewline
    Write-Host ("[adapter-patch] {0} : applied." -f $Label)
}

# --- Patch 1: bounded TE vsync wait ---------------------------------------
$teSyncPath = Join-Path $AdapterRoot 'src/display/display_te_sync.c'
$teSyncMarker = 'PrintSphere local patch: bounded TE-vsync wait'
$teSyncFind = @'
    while (true) {
        if (xSemaphoreTake(ctx->te_vsync_sem, portMAX_DELAY) != pdTRUE) {
            return ESP_ERR_TIMEOUT;
        }
'@
$teSyncReplace = @'
    /* PrintSphere local patch: bounded TE-vsync wait.
     * Upstream uses portMAX_DELAY which deadlocks the LVGL worker if the
     * TE signal is missed (panel quirk, brightness=0, ESD, scheduling jitter).
     * Bound the wait to 100 ms (~6 frames @ 60 Hz) so the flush path can
     * recover by signalling flush_ready and returning the LVGL lock. */
    const TickType_t kTeWaitTicks = pdMS_TO_TICKS(100);
    while (true) {
        if (xSemaphoreTake(ctx->te_vsync_sem, kTeWaitTicks) != pdTRUE) {
            ESP_LOGW(TAG, "TE vsync wait timed out (%ums) -- letting flush proceed without TE sync",
                     (unsigned)pdTICKS_TO_MS(kTeWaitTicks));
            portENTER_CRITICAL(&ctx->lock);
            ctx->frame_request_ticks = 0;
            ctx->window_defer_count = 0;
            portEXIT_CRITICAL(&ctx->lock);
            return ESP_ERR_TIMEOUT;
        }
'@
Apply-Patch -Path $teSyncPath -Marker $teSyncMarker -Find $teSyncFind -Replace $teSyncReplace -Label 'display_te_sync.c (bounded vsync wait)'

# --- Patch 2: bounded TE flush TX-done wait -------------------------------
$bridgePath = Join-Path $AdapterRoot 'src/display/bridge/v9/lvgl_bridge_v9.c'
$bridgeMarker = 'PrintSphere local patch: bound the wait to 200 ms'
$bridgeFind = @'
    /* Wait for transmission to complete */
    ulTaskNotifyValueClear(NULL, ULONG_MAX);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

    display_manager_flush_ready(disp);
}

/**
 * @brief Double buffering with full-screen refresh
 */
'@
$bridgeReplace = @'
    /* Wait for transmission to complete.
     * PrintSphere local patch: bound the wait to 200 ms instead of
     * portMAX_DELAY. If the panel/SPI driver fails to notify (TE quirk,
     * DMA stall under load), the LVGL worker would otherwise block
     * indefinitely and starve every esp_lv_adapter_lock() caller. */
    ulTaskNotifyValueClear(NULL, ULONG_MAX);
    if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(200)) == 0) {
        ESP_LOGW(TAG, "TE flush TX-done notify timed out (200ms) -- releasing LVGL lock");
        if (impl->cfg.te_ctx) {
            esp_lv_adapter_te_sync_record_tx_done(impl->cfg.te_ctx);
        }
    }

    display_manager_flush_ready(disp);
}

/**
 * @brief Double buffering with full-screen refresh
 */
'@
Apply-Patch -Path $bridgePath -Marker $bridgeMarker -Find $bridgeFind -Replace $bridgeReplace -Label 'lvgl_bridge_v9.c (bounded TX-done wait)'

Write-Host "[adapter-patch] done."
