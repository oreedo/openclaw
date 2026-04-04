$sessionsPath = "$HOME/.openclaw/agents/main/sessions"

# Show content before deletion
Write-Host "`n=== Files before deletion ===" -ForegroundColor Cyan
$filesBefore = Get-ChildItem -Path $sessionsPath -Include "*.jsonl", "*.jsonl.lock", "*.jsonl.reset.*", "sessions.json" -Force -ErrorAction SilentlyContinue
if ($filesBefore) {
    $filesBefore | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Yellow }
    Write-Host "Total: $($filesBefore.Count) file(s)" -ForegroundColor Yellow
} else {
    Write-Host "  (no matching files found)" -ForegroundColor Gray
}

# Delete files
Remove-Item -Force -ErrorAction SilentlyContinue "$sessionsPath/*.jsonl"
Remove-Item -Force -ErrorAction SilentlyContinue "$sessionsPath/*.jsonl.lock"
Remove-Item -Force -ErrorAction SilentlyContinue "$sessionsPath/*.jsonl.reset.*"
Remove-Item -Force -ErrorAction SilentlyContinue "$sessionsPath/sessions.json"

# Verify after deletion
Write-Host "`n=== Files after deletion ===" -ForegroundColor Cyan
$filesAfter = Get-ChildItem -Path $sessionsPath -Include "*.jsonl", "*.jsonl.lock", "*.jsonl.reset.*", "sessions.json" -Force -ErrorAction SilentlyContinue
if ($filesAfter) {
    Write-Host "  WARNING: The following files were NOT deleted:" -ForegroundColor Red
    $filesAfter | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Red }
} else {
    Write-Host "  (no matching files remain)" -ForegroundColor Green
    Write-Host "`nCached sessions deleted successfully!" -ForegroundColor Green
}