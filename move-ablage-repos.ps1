# Moves git repos out of the Drive sync corpus (D:\Meine Ablage) to D:\Develop,
# per the mapping agreed in git-repos-in-ablage.md (batch 1, 2026-08-03).
# Same-volume moves = instant renames; nothing is copied or deleted.
#
# Idempotent: an entry whose source is gone and whose target exists is reported
# as already done; collisions (source AND target exist) are skipped with a warning.
#
# Usage:
#   pwsh -File move-ablage-repos.ps1 -DryRun
#   pwsh -File move-ablage-repos.ps1

param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$ablage = "D:\Meine Ablage"

# source (relative to $ablage) => absolute target
$moves = [ordered]@{
    # Akros (explicit targets from the annotated list; 2026 target corrected from apparent 2025 typo)
    "Akros\BäRN Requirements Night\2025"                        = "D:\Develop\Akros\BäRN Requirements Night\2025"
    "Akros\BäRN Requirements Night\2026"                        = "D:\Develop\Akros\BäRN Requirements Night\2026"
    "Akros\CCAI"                                                = "D:\Develop\Akros\CCAI"
    "Akros\Develop\Marvin\maven-maintenance"                    = "D:\Develop\Akros\Marvin\maven-maintenance"
    "Akros\Develop\sommerevent-2025"                            = "D:\Develop\Akros\sommerevent-2025"
    "Akros\Kunden\SBB\Develop\tail\team"                        = "D:\Develop\sbb\team"
    # SV Kt. Bern -> stv-be
    "Akros\Kunden\SV Kt. Bern\Develop\TMO\tmo-dvbtax-common"    = "D:\Develop\stv-be\tmo-dvbtax-common"
    "Akros\Kunden\SV Kt. Bern\Develop\TMO\tmo-taxme-be-common"  = "D:\Develop\stv-be\tmo-taxme-be-common"
    "Akros\Kunden\SV Kt. Bern\Develop\TMO\tmo-taxme-be-np-2022" = "D:\Develop\stv-be\tmo-taxme-be-np-2022"
    "Akros\Kunden\SV Kt. Bern\Develop\TMO\tmo-taxme-be-vs-2022" = "D:\Develop\stv-be\tmo-taxme-be-vs-2022"
    "Akros\Kunden\SV Kt. Bern\Develop\ZPV"                      = "D:\Develop\stv-be\ZPV"
    # Whole FCI tree
    "Develop\FCI"                                               = "D:\Develop\fci"
    # OSS clones with github.com remotes -> D:\Develop\github\<owner>\<repo>
    "Develop\AI\ai-playground"                                  = "D:\Develop\github\danielfrey63\ai-playground"
    "Develop\AI\codel"                                          = "D:\Develop\github\semanser\codel"
    "Develop\AI\devika"                                         = "D:\Develop\github\stitionai\devika"
    "Develop\AI\fooocus\Fooocus"                                = "D:\Develop\github\lllyasviel\Fooocus"
    "Develop\AI\gpt-engineer"                                   = "D:\Develop\github\gpt-engineer-org\gpt-engineer"
    "Develop\AI\gpt-pilot"                                      = "D:\Develop\github\Pythagora-io\gpt-pilot"
    "Develop\AI\open-webui"                                     = "D:\Develop\github\open-webui\open-webui"
    "Develop\AI\OpenDevin"                                      = "D:\Develop\github\OpenDevin\OpenDevin"
    "Develop\AI\Perplexica"                                     = "D:\Develop\github\ItzCrazyKns\Perplexica"
    "Develop\AI\phidata"                                        = "D:\Develop\github\phidatahq\phidata"
    "Develop\AI\ragflow"                                        = "D:\Develop\github\infiniflow\ragflow"
    "Develop\AI\Verba"                                          = "D:\Develop\github\weaviate\Verba"
    "Develop\cors-anywhere"                                     = "D:\Develop\github\Rob--W\cors-anywhere"
    "Develop\getstation\desktop-app"                            = "D:\Develop\github\getstation\desktop-app"
    "Develop\jide-oss"                                          = "D:\Develop\github\danielfrey63\jide-oss"
    "Develop\Liip\drifter"                                      = "D:\Develop\github\liip\drifter"
    "Develop\Liip\LiipImagineBundle"                            = "D:\Develop\github\liip\LiipImagineBundle"
    "Develop\Liip\LiipRokkaImagineBundle"                       = "D:\Develop\github\liip\LiipRokkaImagineBundle"
    "Develop\Liip\RMT"                                          = "D:\Develop\github\liip\RMT"
    "Develop\Liip\styleguide"                                   = "D:\Develop\github\liip\styleguide"
    "Develop\Liip\styleguide-starterkit"                        = "D:\Develop\github\liip\styleguide-starterkit"
    "Develop\Liip\TheA11yMachine"                               = "D:\Develop\github\liip\TheA11yMachine"
    "Develop\Liip\wp-docker-setup"                              = "D:\Develop\github\liip\wp-docker-setup"
    "Develop\Liip\wrench"                                       = "D:\Develop\github\liip\wrench"
    "Develop\Liip\zebra"                                        = "D:\Develop\github\liip\zebra"
    "Develop\memGPT\MemGPT"                                     = "D:\Develop\github\cpacker\MemGPT"
    "Develop\Odoo\Source\bitnami-docker-odoo"                   = "D:\Develop\github\bitnami\bitnami-docker-odoo"
    "Develop\Odoo\Source\docker"                                = "D:\Develop\github\odoo\docker"
    "Develop\Odoo\Source\docker-official-images"                = "D:\Develop\github\odoo\docker-official-images"
    "Develop\Odoo\Source\documentation-user"                    = "D:\Develop\github\odoo\documentation-user"
    "Develop\Odoo\Source\enterprise"                            = "D:\Develop\github\odoo\enterprise"
    "Develop\Odoo\Source\odoo"                                  = "D:\Develop\github\odoo\odoo"
    "Develop\osgi-example\osgi.enroute"                         = "D:\Develop\github\osgi\osgi.enroute"
    "Develop\Pentaho-reports-for-OpenERP"                       = "D:\Develop\github\WillowIT\Pentaho-reports-for-OpenERP"
    "Develop\qwen2.5-VL-inference-openai"                       = "D:\Develop\github\phildougherty\qwen2.5-VL-inference-openai"
    "Develop\QR-Code\qrcode-generator"                          = "D:\Develop\github\bizzycola\qrcode-generator"
    "Develop\spring-petclinic-tests"                            = "D:\Develop\github\freetree-matthias\spring-petclinic-tests"
    "Develop\Temp\browser-samples"                              = "D:\Develop\github\gsuitedevs\browser-samples"
    "Develop\web-ui"                                            = "D:\Develop\github\browser-use\web-ui"
}
# Deliberately NOT moved here:
#  - Develop\Station\desktop-app  (duplicate of getstation/desktop-app - open decision)
#  - Develop\Odoo\Docker\docker   (duplicate of odoo/docker - open decision)
#  - Develop\gh, Develop\Liip\gh, Develop\Liip\ghold (gitlab.liip.ch remotes - open decision)

$ok = 0; $done = 0; $skip = 0; $fail = 0
foreach ($entry in $moves.GetEnumerator()) {
    $src = Join-Path $ablage $entry.Key
    $dst = $entry.Value
    $srcExists = Test-Path -LiteralPath $src
    $dstExists = Test-Path -LiteralPath $dst
    if (-not $srcExists -and $dstExists) { $done++; continue }
    if (-not $srcExists) { Write-Warning "source AND target missing: $($entry.Key)"; $fail++; continue }
    if ($dstExists) { Write-Warning "COLLISION, skipped: $src -> $dst"; $skip++; continue }
    if ($DryRun) { Write-Host "[dry-run] $src -> $dst"; $ok++; continue }
    try {
        $parent = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        # -Force: some Drive-mirrored directories carry ReadOnly attributes
        Move-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "moved: $src -> $dst"
        $ok++
    } catch {
        Write-Warning "FAILED (locked?): $src -- $($_.Exception.Message)"
        $fail++
    }
}
"RESULT moved=$ok alreadyDone=$done collisions=$skip failed=$fail of $($moves.Count)"
