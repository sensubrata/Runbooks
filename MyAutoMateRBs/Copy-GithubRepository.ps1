<#
.SYNOPSIS 
    Copies a GitHub repository to the local sandbox running the runbook

.DESCRIPTION
    Copies a GitHub repository to the local sandbox running the runbook, similar to
    what "git pull" would do. Returns the path to the repository.
    
    Requires a GitHub access token, stored in an encrypted Automation variable asset.
    See https://help.github.com/articles/creating-an-access-token-for-command-line-use 
    for how to generate a token for your Github account.

    When using this runbook, be aware that the memory and disk space size of the
    processes running your runbooks is limited. Because of this, we recommened using
    runbooks only to transfer small repositories. All Automation Integration Module
    assets in your account are loaded into your processes, so be aware that the more
    Integration Modules you have in your system, the smaller the free space your processes
    will have. To ensure maximum disk space in your processes, make sure to clean up any
    local files a runbook transfers or creates before the runbook completes.

.PARAMETER Name
    Name of the GitHub repository to download.

.PARAMETER Author
    Name of the authoring GitHub user or organization for the GitHub repository 

.PARAMETER Branch
    Optional name of the GitHub repository branch to download. If not provided the
    master branch is downloaded.

.PARAMETER GithubTokenVariableAssetName
    Optional name of the Automation variable asset containing the GitHub access token to
    use. If not provided, as Automation variable asset named "GithubToken" will be used.

.EXAMPLE
    Copy-GithubRepository -Name "MyGithubRepository" -Author "joe" -Branch "dev" -GithubTokenVariableAssetName "MyGithubToken"

.NOTES
    AUTHOR: Joe Levy
    LASTEDIT: June 20, 2014 
#>
workflow Copy-GithubRepository
{
    param(
       [Parameter(Mandatory=$True)]
       [string] $Name,
       
       [Parameter(Mandatory=$True)]
       [string] $Author,
       
       [Parameter(Mandatory=$False)]
       [string] $Branch = "master",
       
       [Parameter(Mandatory=$False)]
       [string] $GithubTokenVariableAssetName = "GithubToken"
    )
    
    $ZipFile = "C:\$Name.zip"
    $OutputFolder = "C:\$Name\$Branch"
    
    $Token = Get-AutomationVariable -Name $GithubTokenVariableAssetName
    
    if(!$Token) {
        throw("'$GithubTokenVariableAssetName' variable asset does not exist or is empty.")
    }

    $RepositoryZipUrl = "https://api.github.com/repos/$Author/$Name/zipball/$Branch"

    # download the zip
    Invoke-RestMethod -Uri $RepositoryZipUrl -Headers @{"Authorization" = "token $Token"} -OutFile $ZipFile
    
    # extract the zip
    InlineScript {        
        New-Item -Path $using:OutputFolder -ItemType Directory | Out-Null
        
        [System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($using:ZipFile, $using:OutputFolder)
    }

    # remove zip
    Remove-Item -Path $ZipFile -Force
    
    #output the path to the downloaded repository
    (ls $OutputFolder)[0].FullName
}