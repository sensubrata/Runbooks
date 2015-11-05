workflow Update-AzureVMSize
{

<#
.Synopsis
   Workflow to update Azure VM sizes
.DESCRIPTION
   Workflow to update Azure VM sizes
.PARAMETER WildcardMatch
   This parameter allows for the ability to specify a wildcard match string from which to retreive Azure
   Virtual Machine names. If this paramter is not specified, all virtual machines associated with the connected subscription
   will be retrieved. Refer to the following help topic for a list of supported wildcard characters:
   http://msdn.microsoft.com/en-us/library/aa717088(v=vs.85).aspx.
.PARAMETER InstanceSize
   This required parameter is used to specify the new instance size that will be set for the virtual machines retrieved
   from Azure. A list of possible size options is available here: http://msdn.microsoft.com/library/windowsazure/dn197896.aspx.
.PARAMETER LogFilePath
   This is the path to which the script will output its logging data. It's default logging location is 'C:\Temp\Update-AzureVMSizeLog.txt'.
.EXAMPLE
   Update-AzureVMSize -InstanceSize Large

   This example will retrieve all Azure VMs from the default Azure subscription and change their instance sizes to "Large".
   The default log file path is 'C:\Temp\Update-AzureVMSizeLog.txt'.
.EXAMPLE
   Update-AzureVMSize -WildcardMatch *CONTOSO* -InstanceSize Small -LogFilePath 'C:\Logs\UpdateVMs.txt'

   This example will retrieve all Azure VMs that contain the word "CONTOSO" in the name and change their instance sizes to "Small".
   The log file path is set to 'C:\Logs\UpdateVMs.txt'.
.NOTES
   The machine on which this workflow is executed must have WinRM enabled and properly configured. All execution restrictions associated
   with PowerShell workflows apply to the running of this particular workflow.

   Author: Andrew Weiss | Microsoft Consulting Services
   Date Published: 11/19/2013
   Version: 1.0
#>

    [CmdletBinding(HelpUri = 'https://github.com/anweiss/Azure-PowerShell-Extensible-Workflows')]

    param
    (
        [Parameter()]
        [string]$WildcardMatch,
        [Parameter(mandatory=$true)]
        [string]$InstanceSize,
        [Parameter()]
        [string]$LogFilePath = 'C:\Temp\Update-AzureVMSizeLog.txt'
    )

    $originalErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"

    function FormatLogEntry($entry)
    {
        [String]::Format("{0:s}", (Get-Date)) + ": " + $entry
    }

    try
    {
        # Initialize trace and error variables
        $trace = @()
        $errorMessage = ""
        $errorState = 0

        $trace += FormatLogEntry("'Update-AzureVMSize -InstanceSize $InstanceSize -LogFilePath $LogFilePath' workflow initiated")
        Write-Verbose $trace[$trace.Count - 1]
        $trace += FormatLogEntry("Checking existence of log file path")
        Write-Verbose $trace[$trace.Count - 1]

        # Check for existence of log file and directory path
        if (!(Test-Path $LogFilePath)) {
            $trace += FormatLogEntry("Log file path does not exist. Creating directory and file")
            Write-Verbose $trace[$trace.Count - 1]

            if (!(Test-Path $LogFilePath.Substring(0, $LogFilePath.LastIndexOf('\')))) {
                $trace += FormatLogEntry((New-Item $LogFilePath.Substring(0, $LogFilePath.LastIndexOf('\')) -ItemType Directory).FullName + " directory created")
                Write-Verbose $trace[$trace.Count - 1]
            }
            $trace += FormatLogEntry((New-Item $LogFilePath -ItemType File).FullName + " log file created")
            Write-Verbose $trace[$trace.Count - 1]
        }

        $trace += FormatLogEntry("Retrieving Azure VM objects")
        Write-Verbose $trace[$trace.Count - 1]
        
        # Get Azure VMs
        if ($WildcardMatch) {
            $azureVMs = Get-AzureVM | ? Name -like $using:WildcardMatch
        } else {
            $azureVMs = Get-AzureVM
        }

        # Modify Azure VM instance sizes if VMs have been retrieved
        if ($azureVMs) {
            $trace += FormatLogEntry("VMs retrieved. Updating instance sizes")
            Write-Verbose $trace[$trace.Count - 1]
            foreach -parallel ($VM in $azureVMs)
            {
                $workflow:trace += FormatLogEntry("Updating VM $($VM.Name)")
                Write-Verbose $trace[$trace.Count - 1]
                if ((Get-AzureVM -ServiceName $VM.ServiceName -Name $VM.Name | Set-AzureVMSize -InstanceSize:$InstanceSize | Update-AzureVM).OperationStatus -eq "Succeeded") {
                    $workflow:trace += FormatLogEntry("Successfully updated instance size of VM $($VM.Name)")
                    Write-Verbose $trace[$trace.Count - 1]
                } else {
                    $workflow:trace += FormatLogEntry("Failed to update instance size of VM $($VM.Name)")
                    Write-Verbose $trace[$trace.Count - 1]
                    $workflow:errorState = 1
                }
            }
        } else {
            $trace += FormatLogEntry("No VMs retrieved from Azure")
            Write-Verbose $trace[$trace.Count - 1]
        }
    }
    catch
    {
        $trace += FormatLogEntry("Workflow failed to complete due to the following error:")
        Write-Verbose $trace[$trace.Count - 1]
        $errorMessage = $_.Message
        $errorState = 1
    }
    finally
    {
        if ($errorMessage) { $trace += $errorMessage }
        Write-Verbose $trace[$trace.Count - 1]
        $trace += "`r`n"
        $trace | Out-File -FilePath $LogFilePath -Append
        $ErrorActionPreference = $originalErrorActionPreference
    }
}