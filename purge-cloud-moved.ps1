# Purges cloud-side copies of everything that was moved out of D:\Meine Ablage
# locally on 2026-08-03 (repos relocated to D:\Develop or staged for deletion).
# Without this, "rclone bisync --resync" (a union) would download them again.
#
# Deletions go to the Drive trash (default rclone behaviour) - recoverable 30 days.
# Idempotent: paths already gone are reported as such and skipped.
#
# Usage:
#   pwsh -File purge-cloud-moved.ps1 -DryRun    # only check what exists
#   pwsh -File purge-cloud-moved.ps1            # purge

param([switch]$DryRun)

$ErrorActionPreference = "Stop"

$paths = @(
    "Develop/github"
    # batch-1 moves (see move-ablage-repos.ps1)
    "Akros/BäRN Requirements Night/2025"
    "Akros/BäRN Requirements Night/2026"
    "Akros/CCAI"
    "Akros/Develop/Marvin/maven-maintenance"
    "Akros/Develop/sommerevent-2025"
    "Akros/Kunden/SBB/Develop/tail/team"
    "Akros/Kunden/SV Kt. Bern/Develop/TMO/tmo-dvbtax-common"
    "Akros/Kunden/SV Kt. Bern/Develop/TMO/tmo-taxme-be-common"
    "Akros/Kunden/SV Kt. Bern/Develop/TMO/tmo-taxme-be-np-2022"
    "Akros/Kunden/SV Kt. Bern/Develop/TMO/tmo-taxme-be-vs-2022"
    "Akros/Kunden/SV Kt. Bern/Develop/ZPV"
    "Develop/FCI"
    "Develop/AI/ai-playground"
    "Develop/AI/codel"
    "Develop/AI/devika"
    "Develop/AI/fooocus/Fooocus"
    "Develop/AI/gpt-engineer"
    "Develop/AI/gpt-pilot"
    "Develop/AI/open-webui"
    "Develop/AI/OpenDevin"
    "Develop/AI/Perplexica"
    "Develop/AI/phidata"
    "Develop/AI/ragflow"
    "Develop/AI/Verba"
    "Develop/cors-anywhere"
    "Develop/getstation/desktop-app"
    "Develop/jide-oss"
    "Develop/Liip/drifter"
    "Develop/Liip/LiipImagineBundle"
    "Develop/Liip/LiipRokkaImagineBundle"
    "Develop/Liip/RMT"
    "Develop/Liip/styleguide"
    "Develop/Liip/styleguide-starterkit"
    "Develop/Liip/TheA11yMachine"
    "Develop/Liip/wp-docker-setup"
    "Develop/Liip/wrench"
    "Develop/Liip/zebra"
    "Develop/memGPT/MemGPT"
    "Develop/Odoo/Source/bitnami-docker-odoo"
    "Develop/Odoo/Source/docker"
    "Develop/Odoo/Source/docker-official-images"
    "Develop/Odoo/Source/documentation-user"
    "Develop/Odoo/Source/enterprise"
    "Develop/Odoo/Source/odoo"
    "Develop/osgi-example/osgi.enroute"
    "Develop/Pentaho-reports-for-OpenERP"
    "Develop/qwen2.5-VL-inference-openai"
    "Develop/QR-Code/qrcode-generator"
    "Develop/spring-petclinic-tests"
    "Develop/Temp/browser-samples"
    "Develop/web-ui"
    # trashed duplicates
    "Develop/Station/desktop-app"
    "Develop/Odoo/Docker/docker"
    # stale copies of the 2026-07-30 checkout migration (now in D:\Develop\sbb / \sem)
    "Akros/Kunden/SBB/Develop/agent-rollout"
    "Akros/Kunden/SBB/Develop/ai-guardrail-demo"
    "Akros/Kunden/SBB/Develop/azure-api-mcp-registry"
    "Akros/Kunden/SBB/Develop/brain"
    "Akros/Kunden/SBB/Develop/centralized-agents-experiment"
    "Akros/Kunden/SBB/Develop/contained-agents"
    "Akros/Kunden/SBB/Develop/poc-esta-dfa-weicheneditor-artefakte"
    "Akros/Kunden/SBB/Develop/timo-sdd"
    "Akros/Kunden/SBB/Develop/dokumentations-tools"
    "Akros/Kunden/SEM/Auftrag"
    # old cloud names of dirs renamed locally after 2026-07-27
    "Privat/Viseca/Ald"
)
# trashed SBB repository clones (mirror of D:\_trash-ablage-repos\SBB-Repository)
$sbbTrash = Get-ChildItem "D:\_trash-ablage-repos\SBB-Repository" -Directory -ErrorAction SilentlyContinue
$paths += $sbbTrash | ForEach-Object { "Akros/Kunden/SBB/Repository/$($_.Name)" }

$purged = 0; $gone = 0; $failed = 0
foreach ($p in $paths) {
    & rclone lsf "gdrive:$p" --max-depth 1 --dirs-only 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # distinguish "not found" from other errors only loosely; lsf exits 3 on missing dir
        "already gone: $p"
        $gone++
        continue
    }
    if ($DryRun) { "[dry-run] would purge: $p"; $purged++; continue }
    & rclone purge "gdrive:$p" --drive-use-trash 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { "purged: $p"; $purged++ }
    else { Write-Warning "FAILED: $p"; $failed++ }
}
"RESULT purged=$purged alreadyGone=$gone failed=$failed of $($paths.Count)"
