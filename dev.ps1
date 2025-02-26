﻿# This script is for local development purposes only to make it easier
# for developers to work with all the various scripts and their parameters.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'BuildRelease',
        'StartWebsiteLocallyDevMode',
        'StartWebsiteLocallyProdMode',
        'DeployToAzure',
        'RunE2ETests',
        'Push',
        'DestroyAzureEnvironment'
    )]
    [String]
    $Workflow
)

Set-StrictMode –Version latest

$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

enum DevWorkflows {
    BuildRelease
    StartWebsiteLocallyDevMode
    StartWebsiteLocallyProdMode
    DeployToAzure
    RunE2ETests
    Push
    DestroyAzureEnvironment
}

function Invoke-Workflow {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [DevWorkflows]
        $Workflow
    )

    # Load some configuration values...
    $GlobalDevelopmentSettings = Get-Content 'dev/development-config.json' | ConvertFrom-Json

    $DevelopmentToolsDirectory = $GlobalDevelopmentSettings.DevelopmentToolsDirectory

    . "$DevelopmentToolsDirectory/local-config-manager.ps1"

    $DeveloperEnvironmentSettings = Get-EnvironmentSettingsObject

    switch ($Workflow) {
        BuildRelease
        {
            Invoke-Build `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings
        }

        DeployToAzure
        {
            Invoke-Deploy `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings
        }

        DestroyAzureEnvironment
        {
            Invoke-Destroy `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings
        }

        Push
        {
            Invoke-Push `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings
        }

        StartWebsiteLocallyDevMode
        {
            Start-Website `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings `
                -Mode                           Dev
        }

        StartWebsiteLocallyProdMode
        {
            Start-Website `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings `
                -Mode                           Prod
        }

        RunE2ETests
        {
            Invoke-E2ETests `
                -GlobalDevelopmentSettings      $GlobalDevelopmentSettings `
                -DeveloperEnvironmentSettings   $DeveloperEnvironmentSettings
        }

        default { throw "The specified workflow '${Workflow}' is not implemented." }
    }
}

function Invoke-Build {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Object]
        $GlobalDevelopmentSettings,

        [Parameter(Mandatory = $true)]
        [Object]
        $DeveloperEnvironmentSettings
    )

    try {
        Push-Location $GlobalDevelopmentSettings.SourceDirectory

        $BuildNumber = [Guid]::NewGuid()

        ./build.ps1 `
            -BuildNumber                    $BuildNumber `
            -FlexportApiClientID            $DeveloperEnvironmentSettings.FlexportApiClientID `
            -FlexportApiClientSecret        $DeveloperEnvironmentSettings.FlexportApiClientSecret

        Write-Information ""
        Write-Information "To run the build locally:"
        Write-Information ""
        Write-Information "   ./dev StartWebsiteLocallyDevMode"
        Write-Information "   ./dev StartWebsiteLocallyProdMode"
        Write-Information ""
        Write-Information "To deploy the build to Azure:"
        Write-Information ""
        Write-Information "   ./dev DeployToAzure"
        Write-Information ""
    }
    finally {
        Pop-Location
    }
}

function Invoke-Deploy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Object]
        $GlobalDevelopmentSettings,

        [Parameter(Mandatory = $true)]
        [Object]
        $DeveloperEnvironmentSettings
    )

    $ReleasablesPath           = $GlobalDevelopmentSettings.ReleasablesDirectory
    $DevelopmentToolsDirectory = $GlobalDevelopmentSettings.DevelopmentToolsDirectory

    . "$DevelopmentToolsDirectory/sign-into-azure.ps1"
    . "$DevelopmentToolsDirectory/build-number.ps1"

    $BuildNumber = Get-BuildNumber

    try {
        Push-Location $ReleasablesPath

        ./deploy-earth.ps1 `
            -BuildNumber                  $BuildNumber `
            -EnvironmentName              $DeveloperEnvironmentSettings.EnvironmentName `
            -EarthWebsiteCustomDomainName $DeveloperEnvironmentSettings.EarthWebsiteCustomDomainName `
            -FlexportApiClientId          $DeveloperEnvironmentSettings.FlexportApiClientId `
            -FlexportApiClientSecret      $DeveloperEnvironmentSettings.FlexportApiClientSecret `
            -GoogleAnalyticsMeasurementId $DeveloperEnvironmentSettings.GoogleAnalyticsMeasurementId
    }
    finally {
        Pop-Location
    }
}

function Invoke-Destroy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Object]
        $GlobalDevelopmentSettings,

        [Parameter(Mandatory = $true)]
        [Object]
        $DeveloperEnvironmentSettings
    )

    $DevelopmentToolsDirectory = $GlobalDevelopmentSettings.DevelopmentToolsDirectory
    $RelesablesDirectory       = $GlobalDevelopmentSettings.ReleasablesDirectory

    . "$DevelopmentToolsDirectory/sign-into-azure.ps1"

    try {
        Push-Location $RelesablesDirectory

        ./destroy-earth.ps1 `
            -EnvironmentName $DeveloperEnvironmentSettings.EnvironmentName
    }
    finally {
        Pop-Location
    }
}

function Invoke-Push {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Object]
        $GlobalDevelopmentSettings,

        [Parameter(Mandatory = $true)]
        [Object]
        $DeveloperEnvironmentSettings
    )

    $RelesablesDirectory = $GlobalDevelopmentSettings.ReleasablesDirectory

    # Run dependency management
    . "$RelesablesDirectory/dependencies/dependency-manager.ps1"

    # Make sure there's no pending changes.
    $GitStatus = git status

    if (-Not ($GitStatus -like "*nothing to commit*")) {
        Write-Error "You have pending changes that need to be committed."
    }

    # Make sure we're testing with latest from origin/main.
    git fetch origin main

    $CurrentBranchName       = git rev-parse --abbrev-ref HEAD
    $DiffCounts              = ((git rev-list --left-right --count origin/main...$CurrentBranchName) -split '\t')
    $CommitsBehindOriginMain = $DiffCounts[0]

    if ($CommitsBehindOriginMain -gt 0) {
        Write-Error "The current branch is behind origin/main by $CommitsBehindOriginMain, please update it before continuing."
    }

    Invoke-Build   -GlobalDevelopmentSettings $GlobalDevelopmentSettings -DeveloperEnvironmentSettings $DeveloperEnvironmentSettings
    Invoke-Deploy  -GlobalDevelopmentSettings $GlobalDevelopmentSettings -DeveloperEnvironmentSettings $DeveloperEnvironmentSettings
    Invoke-Destroy -GlobalDevelopmentSettings $GlobalDevelopmentSettings -DeveloperEnvironmentSettings $DeveloperEnvironmentSettings

    git push --set-upstream origin $CurrentBranchName
}

enum LocalWebsiteModes {
    Dev
    Prod
}

function Start-Website {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Object]
        $GlobalDevelopmentSettings,

        [Parameter(Mandatory = $true)]
        [Object]
        $DeveloperEnvironmentSettings,

        [Parameter(Mandatory = $true)]
        [LocalWebsiteModes]
        $Mode
    )

    $WebsiteContentDirectory = $GlobalDevelopmentSettings.WebsiteContentSourceDirectory

    try {
        Push-Location $WebsiteContentDirectory

        $GoogleAnalyticsMeasurementId = $DeveloperEnvironmentSettings.GoogleAnalyticsMeasurementId

        # Set environment variables that the website requires before starting.
        $env:NEXT_PUBLIC_GOOGLE_ANALYTICS_MEASUREMENT_ID=$GoogleAnalyticsMeasurementId

        switch ($Mode) {
            Dev
            {
                npm run dev
            }

            Prod
            {
                npm run start
            }

            default { throw "The specified mode '${Mode}' is not valid." }
        }
    }
    finally {
        Pop-Location

        # Clean up env vars
        Remove-Item Env:\NEXT_PUBLIC_GOOGLE_ANALYTICS_MEASUREMENT_ID
    }
}

function Invoke-E2ETests {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Object]
        $GlobalDevelopmentSettings,

        [Parameter(Mandatory = $true)]
        [Object]
        $DeveloperEnvironmentSettings
    )

    $DevelopmentToolsDirectory  = $GlobalDevelopmentSettings.DevelopmentToolsDirectory
    $RelesablesDirectory        = $GlobalDevelopmentSettings.ReleasablesDirectory

    . "$DevelopmentToolsDirectory/build-number.ps1"

    $BuildNumber = Get-BuildNumber

    try {
        Push-Location "$RelesablesDirectory"

        ./test-earth.ps1 `
            -EarthWebsiteUrl http://localhost:3000 `
            -BuildNumber     $BuildNumber
    }
    finally {
        Pop-Location
    }

}

# Ensure all the local development tools are installed
# and up to date before running any development workflows.
./dev/tools/install-development-tools.ps1

Invoke-Workflow -Workflow $Workflow
