<#
.SYNOPSIS 
    Azure Automation logging function to output logs to screen and store in database.

.DESCRIPTION
    Utilizes an Azure SQL database to store log messages that are less than or equal
    to the global error logging level, after outputting them to the Azure console.

    Depends on the following Automation Assets:
        > WKAzureErrorLogging Level - defines the global logging level for account
        > WKAzureSQLUserName - defines the username to connect to a SQL server
        > WKAzureSQLPassword (encrypted) - defines the password to connect to a SQL server
        > WKAzureSQLServerName - defines the SQL server to connect to
        > WKAzureSQLLogDatabase - defines the database to connect to for logging
        > WKAzureSQLLogTable - defines the table to connect to for logging

    The SQL table can be created using the following SQL script:
    ==========================================================
    CREATE TABLE [dbo].[wkloggingdb](
        [PId] [int] IDENTITY(1,1) NOT NULL, 
	    [LogLevel] [int] NULL,
	    [MessageDetails] [nvarchar](Max) NULL,
	    [RunbookName] [nvarchar](Max) NULL,
	    [Timestamp] [datetime] NULL,
	    [OperationID] [uniqueidentifier] NULL,
    )
    CREATE CLUSTERED INDEX wkloggingdb_Idx ON wkloggingdb(PId)
    ==========================================================

.PARAMETER Level
    Indicates log level of message.

.PARAMETER Message
    Contains the actual log contents.

.PARAMETER RunbookName
    Contains the name of the runbook calling the log function.

.PARAMETER OperationID
    Optional: a guid to use for operation tracking. One is generated if not provided

.NOTES
    AUTHOR: Wes Kroesbergen
    LASTEDIT: Oct. 20, 2014 
#>

workflow Write-SQLLog
{
    param (
       [Parameter(Mandatory=$False)]
       [int] $Level = 3,
       [Parameter(Mandatory=$False)]
       [string] $Message = "Failed to pass a message to logging function!",
       [Parameter(Mandatory=$False)]
       [string] $RunbookName = "No runbook name given",
       [Parameter(Mandatory=$False)]
       [string] $OperationID
    )
    # Retrieve our global Azure error logging level
    $globalLogLevel = Get-AutomationVariable -Name "WKAzureErrorLoggingLevel"
    
    # Retrieve our logging database connection variables
    $AzureSQLUserName = Get-AutomationVariable -Name "WKAzureSQLUserName"
    $AzureSQLPassword = Get-AutomationVariable -Name "WKAzureSQLPassword"
    $AzureSQLServerName = Get-AutomationVariable -Name "WKAzureSQLServerName"
    $AzureSQLLogDatabase = Get-AutomationVariable -Name "WKAzureSQLLogDatabase"
    $AzureSQLLogTable = Get-AutomationVariable -Name "WKAzureSQLLogTable"

    if(!$OperationID)
    {
        $OperationID = [GUID]::NewGuid()
    }
    
    InlineScript {
        $stopLoop = $false
        [int]$retryCount = "0"
        do 
        {
            # Log an error if error level is less than global level
            if ($using:level -le $using:globalLogLevel)
            {
                $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss.000"

                Write-Output "$time - $using:Message"
                
                try
                {
                    # Connect to our Azure SQL database
                    $AzureSQLDBConnection = New-Object System.Data.SqlClient.SqlConnection
                    $AzureSQLDBConnection.ConnectionString = "Server = $using:AzureSQLServerName; Database = $using:AzureSQLLogDatabase; User ID = $using:AzureSQLUserName; Password = $using:AzureSQLPassword;"
                    $AzureSQLDBConnection.Open();

                    # Create a command to retrieve our errors
                    $AzureSQLDBCommand = New-Object System.Data.SqlClient.SqlCommand
                    $AzureSQLDBCommand.Connection = $AzureSQLDBConnection
                    $AzureSQLDBCommand.CommandText = "INSERT [$using:AzureSQLLogTable] (LogLevel, MessageDetails, RunbookName, Timestamp, OperationID) VALUES ('{0}','{1}','{2}','{3}','{4}')" -f $using:Level, $using:Message, $using:RunbookName, $using:time, $using:OperationID

                    # Execute our command
                    $AzureSQLDBCommand.ExecuteNonQuery() | Out-Null
            
                    # Close our SQL connection
                    $AzureSQLDBConnection.Close() | Out-Null

                    $stopLoop = $true
                }
                catch
                {
                    if ($retryCount -gt 2) { 
                        $stopLoop = $true 
                        Write-Output "$time - Failed to insert after 2 attempts, stopping..."
                    }
                    else { 
                        $retryCount++
                        Write-Output "$time - ERROR: $($_.Exception.Message)"
                        Write-Output "$time - Retrying attempt $retryCount..."
                    }
                }
            }
            else {$stopLoop = $true}
        }
        while ($stopLoop -eq $False)
    }
}
#EndRegion