##########################################################################################################
<#
.SYNOPSIS
    Creates a Windows Server 2012 R2 Active Directory forest in Windows Azure.
    
.DESCRIPTION
    As a minimum will create a forest with one domain and one domain controller. Additional domain 
    controllers can be specified. Additional member servers can be added. 

.EXAMPLE
	.\Azure_AD_Build.ps1 -ServicePrefix "NIMBUS" `
                         -Location "North Europe" `
                         -AdminUser "CloudAdmin" `
                         -AdminPassword "2BYlKZ9pWN" `
                         -ForestFqdn "contoso.com" `
                         -Domain "contoso" `
                         -DcCount 4 `
                         -MemberCount 1 `
                         -W7ClientCount 1 `
                         -W8ClientCount 1 `
                         -W10ClientCount 1 `
                         -ClassCSubnetNumber 11     

    Creates a virtual network and storage account in the 'North Europe' data centre location both prefixed 
    with 'NIMBUS'. The virtual network has one subnet - 10.0.11.0/28. 
    
    Creates a forest called contoso.com with 4 Windows Server 2012 R2 domain controllers, 1 Windows Server 
    2012 R2member serve, 1 Windows 7 Enterprise (x64) client, 1 Windows 8.1 Enterprise (x64) client and 
    1 Windows 10 Enterprise (x64) client. 
    An Azure DNS object is created for the first DC on 10.0.11.4. The domain controllers will each have 
    an additional 20GB data drive, with host caching disabled, for the NTDS and SYSVOL folders. The 
    domain controllers will also have a static Azure vNet IP set. Creates a domain administrator and, 
    where appropriate a local administrator account called 'CloudAdmin', with a password of '2BYlKZ9pWN'. 
    Sets the DSRM password as '2BYlKZ9pWN'.

    A certificate for each host will be imported to the local computer's 'Trusted Root Certificate Store' 
    to allow seamless connectivity using PS Remoting.

.EXAMPLE
	.\Azure_AD_Build.ps1 -ServicePrefix "FARRCLOUD" `
                         -AdminUser "CloudAdmin" `
                         -AdminPassword "2BYlKZ9pWN" 

    Creates a virtual network and storage account in the 'West Europe' data centre location both prefixed 
    with 'FARRCLOUD'. The virtual network has one subnet - 10.0.10.0/28.  
    
    Creates a forest called adatum.com with 1 Windows Server 2012 R2 domain controller. An Azure DNS object 
    is created for the DC on 10.0.10.4. The domain controller will have an additional 20GB data drive, with 
    host caching disabled, for the NTDS and SYSVOL folders. The domain controller will also have a static 
    Azure vNet IP set. Creates a domain administrator account called 'CloudAdmin', with a password of 
    '2BYlKZ9pWN'. Sets the DSRM password as '2BYlKZ9pWN'.

    A certificate for the domain controller will be imported to the local computer's 'Trusted Root Certificate 
    Store' to allow seamless connectivity using PS Remoting.

.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.

    This sample is not supported under any Microsoft standard support program or service. 
    The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
    implied warranties including, without limitation, any implied warranties of merchantability
    or of fitness for a particular purpose. The entire risk arising out of the use or performance
    of the sample and documentation remains with you. In no event shall Microsoft, its authors,
    or anyone else involved in the creation, production, or delivery of the script be liable for 
    any damages whatsoever (including, without limitation, damages for loss of business profits, 
    business interruption, loss of business information, or other pecuniary loss) arising out of 
    the use of or inability to use the sample or documentation, even if Microsoft has been advised 
    of the possibility of such damages, rising out of the use of or inability to use the sample script, 
    even if Microsoft has been advised of the possibility of such damages. 

#>
##########################################################################################################

###############################
## SCRIPT OPTIONS & PARAMETERS
###############################

#Requires -Version 3
#Requires -RunAsAdministrator
#Requires -Modules Azure

#Version: 5.3
<# - 29/01/2015 
     * added ability to merge additional vNet configuration with existing configuration so that script can 
       be used to create a forest in a non-vanilla subscription
     * added ability to specify class C subnet number for virtual network

   - 24/02/2015
     * added the ability to spin up Win7 and Win8 clients
     * made the script verbose by default

   - 17/03/2015
     * added additional parameter validation on the -ServicePrefix parameter to check that the name doesn't 
       already exist

   - 16/09/2015
     * added ability to spin up W10 clients
     * fixed an issue with retrieval of W7 / W8 VM images
     * updated data centre locations
#>

#Define and validate mandatory parameters
[CmdletBinding()]
Param(
      #The Cloud Service name, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateLength(2,9)]
      [ValidateScript({!(Test-AzureName -Service $_)})] 
      [String]$ServicePrefix,

      #The data centre location of the build items
      [parameter(Position=2)]
      [ValidateSet("Brazil South",`
                   "Central US",`
                   "East Asia",`
                   "East US",`
                   "East US 2",`
                   "Japan East",`
                   "Japan West",`
                   "North Central US",`
                   "North Europe",`
                   "South Central US",`
                   "Southeast Asia",`
                   "West Europe",`
                   "West US")]
      [String]$Location = "West Europe",

      #The admin user account 
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminUser,

      #The admin user password
      [parameter(Mandatory,Position=4)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminPassword,

      #The FQDN of the Active Directory forest to create
      [parameter(Position=5)]
      [String]$ForestFqdn = "adatum.com",

      #The NetBios name of the Active Directory domain to create
      [parameter(Position=6)]
      [String]$Domain = "adatum",

      #The total number of DCs to spin up
      [parameter(Position=7)]
      [ValidateRange(1,4)]
      [Single]$DcCount = 1,

      #The number of member servers to spin up
      [parameter(Position=8)]
      [ValidateRange(0,4)]
      [Single]$MemberCount = 0,

      #The number of Win7 clients to spin up
      [parameter(Position=9)]
      [ValidateRange(0,4)]
      [Single]$W7ClientCount = 0,

      #The number of Win8 clients to spin up
      [parameter(Position=10)]
      [ValidateRange(0,4)]
      [Single]$W8ClientCount = 0,

       #The number of Win10 clients to spin up
      [parameter(Position=11)]
      [ValidateRange(0,4)]
      [Single]$W10ClientCount = 0,

      #Specifies the value of the Class C subnet to be created for the virtual network, e.g. X in 10.0.X.0
      [parameter(Position=12)]
      [ValidateRange(0,255)]
      [Single]$ClassCSubnetNumber = 10
      )


#Set strict mode to identify typographical errors
Set-StrictMode -Version Latest

#Let's make the script verbose by default
$VerbosePreference = "Continue"


##########################################################################################################

#######################################
## FUNCTION 1 - Create-AzurevNetCfgFile
#######################################

#Creates a NetCfg XML file to be consumed by Set-AzureVNetConfig

Function Create-AzurevNetCfgFile {

Param(
      #The name used to prefix all build items, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      [String]$ServicePrefix,

      #The data centre location of the build items
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$Location,

      #The netcfg file path
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      [String]$NetCfgFile
      )

#Define a here-string for our NetCfg xml structure
$NetCfg = @"
<?xml version="1.0" encoding="utf-8"?>
<NetworkConfiguration xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://schemas.microsoft.com/ServiceHosting/2011/07/NetworkConfiguration">
  <VirtualNetworkConfiguration>
    <Dns>
      <DnsServers>
        <DnsServer name="$($ServicePrefix)DC01" IPAddress="10.0.$($ClassCSubnetNumber).4" />
      </DnsServers>
    </Dns>
    <VirtualNetworkSites>
      <VirtualNetworkSite name="$($ServicePrefix)vNet" Location="$($Location)">
        <AddressSpace>
          <AddressPrefix>10.0.$($ClassCSubnetNumber).0/24</AddressPrefix>
        </AddressSpace>
        <Subnets>
          <Subnet name="$($ServicePrefix)Subnet1">
            <AddressPrefix>10.0.$($ClassCSubnetNumber).0/28</AddressPrefix>
          </Subnet>
        </Subnets>
        <DnsServersRef>
          <DnsServerRef name="$($ServicePrefix)DC01" />
        </DnsServersRef>
      </VirtualNetworkSite>
    </VirtualNetworkSites>
  </VirtualNetworkConfiguration>
</NetworkConfiguration>
"@

    #Update the NetCfg file with parameter values
    Set-Content -Value $NetCfg -Path $NetCfgFile

    #Error handling
    If (!$?) {

        #Write Error and exit
        Write-Error "Unable to create $NetCfgFile with custom vNet settings" -ErrorAction Stop

    }   #End of If (!$?)
    Else {

        #Troubleshooting message
        Write-Verbose "$(Get-Date -f T) - $($NetCfgFile) successfully created"

    }   #End of Else (!$?)


}   #End of Function Create-AzurevNetCfgFile



##########################################################################################################

#######################################
## FUNCTION 2 - Update-AzurevNetConfig
#######################################

Function Update-AzurevNetConfig {

Param(
      #The name used to prefix all build items, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      [String]$vNetName,

      #The netcfg file path
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$NetCfgFile
      )


#Attempt to retrive vNet config
$vNetConfig = Get-AzureVNetConfig

    #If we don't have an existing virtual network use the netcfg file to create a new one
    If (!$vNetConfig) {
    
        #Write the fact that we don't have a vNet config file to screen
        Write-Verbose "$(Get-Date -f T) - Existing Azure vNet configuration not found"
    
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Creating $vNetName virtual network from $NetCfgFile"
        Write-Debug "About to create $vNetName virtual network from $NetCfgFile"
    
        #Create a new virtual network from the config file
        Set-AzureVNetConfig -ConfigurationPath $NetCfgFile -ErrorAction SilentlyContinue | Out-Null
    
            #Error handling
            If (!$?) {
    
                #Write Error and exit
                Write-Error "Unable to create $vNetName virtual network" -ErrorAction Stop
    
            }   #End of If (!$?) 
            Else {
    
                #Troubleshooting message
                Write-Verbose "$(Get-Date -f T) - $vNetName virtual network successfully created"
    
            }   #End of Else (!$?)
    
    }   #End of If (!$vNetConfig)
    
    #If we find a virtual network configuration update the existing one
    Else {
    
        #Write confirmation of existing vNet config to screen
        Write-Verbose "$(Get-Date -f T) - Existing Azure vNet configuration found"
    
        #Set the vNetConfig update flag to false (this determines if changes are committed later)
        $UpdatevNetConfig = $False
    
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Backing up existing vNetConfig to $($NetCfgFile).backup"
        Write-Debug "About to backup up existing vNetConfig to $($NetCfgFile).backup"
    
        #Backup the existing vNet configuration
        Set-Content -Value $vNetConfig.XMLConfiguration -Path "$($NetCfgFile).backup" -Force
    
            #Error handling
            If (!$?) {
    
                #Write Error and exit
                Write-Error "Unable to backup existing vNetConfig" -ErrorAction Stop
    
            }   #End of If (!$?) 
            Else {
    
                #Troubleshooting message
                Write-Verbose "$(Get-Date -f T) - vNetConfig backed up to $($NetCfgFile).backup"
    
            }   #End of Else (!$?)
    
    
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Reading contents of $NetCfgFile"
        Write-Debug "About to read contents of $NetCfgFile"
    
        #Convert previously created NetCfgFile to XML
        [XML]$NetCfg = Get-Content -Path $NetCfgFile
    
            #Error handling
            If (!$?) {
    
                #Write Error and exit
                Write-Error "Unable to convert $NetCfgFile to XML object" -ErrorAction Stop
    
            }   #End of If (!$?) 
            Else {
    
                #Troubleshooting message
                Write-Verbose "$(Get-Date -f T) - $NetCfgFile successfully converted to XML object"
    
            }   #End of Else (!$?)
    
            
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Converting existing vNetConfig object to XML"
        Write-Debug "About to convert existing vNetConfig object to XML"
    
        #Convert vNetConfig (VirtualNetworkConfigContext object) to XML
        $vNetConfig = [XML]$vNetConfig.XMLConfiguration
    
            #Error handling
            If (!$?) {
    
                #Write Error and exit
                Write-Error "Unable to convert vNetConfig object to XML object" -ErrorAction Stop
    
            }   #End of If (!$?) 
            Else {
    
                #Troubleshooting message
                Write-Verbose "$(Get-Date -f T) - vNetConfig object successfully converted to XML object"
    
            }   #End of Else (!$?)
    
        
        ###Check for existence of DNS entry
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Checking for Dns node"
        Write-Debug "About to check for Dns node"
    
        #Get the Dns child of the VirtualNetworkConfiguration Node
        $DnsNode = $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.ChildNodes | Where-Object {$_.Name -eq "Dns"}
    
        #Check if the Dns node was found
        If ($DnsNode) {
    
            #Update comment
            Write-Verbose "$(Get-Date -f T) - Dns node found"
    
            #Now check for whether Dns node is empty
            If ($DnsNode.HasChildNodes -eq $False) {
    
                #Write that no existing DNS servers were found to screen
                Write-Verbose "$(Get-Date -f T) - No existing DNS servers found"
    
                #Troubleshooting messages
                Write-Verbose "$(Get-Date -f T) - Adding DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
                Write-Debug "About to add DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
    
                #Create a template for the DNS node
                $DnsEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.Dns, $True)
                
                #Import the newly created template
                $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.ReplaceChild($DnsEntry, $DnsNode) | Out-Null
    
                    #Error handling
                    If (!$?) {
    
                        #Write Error and exit
                        Write-Error "Unable to replace DNS server node" -ErrorAction Stop
    
                    }   #End of If (!$?) 
                    Else {
    
                        #Troubleshooting message
                        Write-Verbose "$(Get-Date -f T) - DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) - added to in-memory network configuration"

                        #Set the vNetConfig update flag to true so we know we have changes to commit later
                        $UpdatevNetConfig = $True
    
                    }   #End of Else (!$?)
    
            }   #End of If ($DnsNode.HasChildNodes -eq $False)
            Else {
    
                #Write that we have found child nodes
                Write-Verbose "$(Get-Date -f T) - DNS node has child nodes"

                #Troubleshooting messages
                Write-Verbose "$(Get-Date -f T) - Checking for Dns servers in child nodes"
                Write-Debug "About to check for Dns servers in child nodes"

                #Check that DnsServers exists
                If (($DnsNode.FirstChild).Name -eq "DnsServers") {

                    #Now, check whether we have any DNS entries
                    If ($DnsNode.DnsServers.HasChildNodes) {

                        #Write confirmation of existing DNS servers to screen
                        Write-Verbose "$(Get-Date -f T) - Existing DNS servers found"

                        #Get a list of currently configured DNS servers
                        $DnsServers = $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.Dns.DnsServers.DnsServer

                        #Troubleshooting messages
                        Write-Verbose "$(Get-Date -f T) - Checking for DNS server conflicts"
                        Write-Debug "About to check for DNS server conflicts"

                        #Set $DnsAction as "Update"
                        $DnsAction = "Update"

                        #Loop through the DNS server entries
                        $DnsServers | ForEach-Object {

                            #See if we have the DNS server or IP address already in use
                            If (($_.Name -eq "$($ServicePrefix)DC01") -and ($_.IPAddress -eq "10.0.$($ClassCSubnetNumber).4")) {
                                
                                #Set a flag for a later action
                                $DnsAction = "NoFurther"

                            }   #End of If (($_.Name -eq "$($ServicePrefix)DC01") -and $_.IPAddress -eq "10.0.$($ClassCSubnetNumber).4")

                            ElseIf (($_.Name -eq "$($ServicePrefix)DC01") -xor ($_.IPAddress -eq "10.0.$($ClassCSubnetNumber).4")) {

                                #Set a flag for a later action
                                $DnsAction = "PotentialConflict"

                            }   #End of ElseIf (($_.Name -eq "$($ServicePrefix)DC01") -xor ($_.IPAddress -eq "10.0.$($ClassCSubnetNumber).4"))
                

                        }   #End of ForEach-Object

                        #Perform appropriate action after looping through all DNS entries
                        Switch ($DnsAction) {

                            "NoFurther" {
                        
                                #Write confirmation that our DNS server already exists
                                Write-Verbose "$(Get-Date -f T) - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) already exists - no further action required"
                        
                            }   #End of "NoFurther"


                            "PotentialConflict" {

                                #Write confirmation that one element of our DNS server's setting already exist
                                Write-Error "There is a name or IP conflict with an existing DNS server - please investigate" -ErrorAction Stop
                        
                            }   #End of "PotentialConflict"

                            Default {
 
                                ##As the first two conditions aren't met, it must be safe to update the node
                                #Troubleshooting messages
                                Write-Verbose "$(Get-Date -f T) - No conflicts found"
                                Write-Verbose "$(Get-Date -f T) - Adding DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
                                Write-Debug "About to add DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"

                                #Create a template for an entry to the DNSservers node
                                $DnsServerEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.Dns.DnsServers.DnsServer, $True)

                                #Add the template to out copy of the vNetConfig in memory
                                $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.Dns.DnsServers.AppendChild($DnsServerEntry) | Out-Null

                                    #Error handling
                                    If (!$?) {

                                        #Write Error and exit
                                        Write-Error "Unable to append DNS server" -ErrorAction Stop

                                    }   #End of If (!$?) 
                                    Else {

                                        #Troubleshooting message
                                        Write-Verbose "$(Get-Date -f T) - DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) - added to in-memory network configuration"

                                        #Set the vNetConfig update flag to true so we know we have changes to commit later
                                        $UpdatevNetConfig = $True

                                    }   #End of Else (!$?)                      
                        
                            }   #End of Default
                                              
                        }   #End of Switch ($DnsAction)

                    }   #End of If ($DnsNode.DnsServers.HasChildNodes)
                    Else {

                        #Write that no existing DNS servers were found to screen
                        Write-Verbose "$(Get-Date -f T) - No existing DNS server entries found in child nodes"
    
                        #Troubleshooting messages
                        Write-Verbose "$(Get-Date -f T) - Adding DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
                        Write-Debug "About to add DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
    
                        #Create a template for the DNS node
                        $DnsEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.Dns, $True)
                
                        #Import the newly created template
                        $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.ReplaceChild($DnsEntry, $DnsNode) | Out-Null
    
                            #Error handling
                            If (!$?) {
    
                                #Write Error and exit
                                Write-Error "Unable to replace DNS server node" -ErrorAction Stop
    
                            }   #End of If (!$?) 
                            Else {
    
                                #Troubleshooting message
                                Write-Verbose "$(Get-Date -f T) - DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) - added to in-memory network configuration"
                                
                                #Set the vNetConfig update flag to true so we know we have changes to commit later
                                $UpdatevNetConfig = $True

                            }   #End of Else (!$?)

                    }   #End of Else ($DnsNode.DnsServers.HasChildNodes)


                }   #End of If (($DnsNode.FirstChild).Name -eq "DnsServers")
                Else {

                    #Write that no existing DNS servers were found to screen
                    Write-Verbose "$(Get-Date -f T) - No existing DNS server entries found in child nodes"
    
                    #Troubleshooting messages
                    Write-Verbose "$(Get-Date -f T) - Adding DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
                    Write-Debug "About to add DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
    
                    #Create a template for the DNS node
                    $DnsEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.Dns, $True)
                    
                    #Import the newly created template
                    $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.ReplaceChild($DnsEntry, $DnsNode) | Out-Null
    
                        #Error handling
                        If (!$?) {
    
                            #Write Error and exit
                            Write-Error "Unable to replace DNS server node" -ErrorAction Stop
    
                        }   #End of If (!$?) 
                        Else {
    
                            #Troubleshooting message
                            Write-Verbose "$(Get-Date -f T) - DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) - added to in-memory network configuration"

                            #Set the vNetConfig update flag to true so we know we have changes to commit later
                            $UpdatevNetConfig = $True
    
                        }   #End of Else (!$?)

                }   #End of Else (($DnsNode.FirstChild).Name -eq "DnsServers")
    
    
            }   #End of Else ($DnsNode.HasChildNodes -eq $False)
    
    
        }   #End of If ($DnsNode.Name -eq "Dns")
        Else {
    
            #Write that Dns node not found to screen
            Write-Verbose "$(Get-Date -f T) - Dns node not found"
    
            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Adding DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
            Write-Debug "About to add DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) to network configuration"
    
            #Create a template for the DNS node
            $DnsEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.Dns, $True)
            
            #Import the newly created template
            $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.AppendChild($DnsEntry) | Out-Null
    
                #Error handling
                If (!$?) {
    
                    #Write Error and exit
                    Write-Error "Unable to  DNS server node" -ErrorAction Stop
    
                }   #End of If (!$?) 
                Else {
    
                    #Troubleshooting message
                    Write-Verbose "$(Get-Date -f T) - DNS Server - $($ServicePrefix)DC01 (10.0.$($ClassCSubnetNumber).4) - added to in-memory network configuration"

                    #Set the vNetConfig update flag to true so we know we have changes to commit later
                    $UpdatevNetConfig = $True
    
                }   #End of Else (!$?)
    
        }   #End of Else ($DnsNode)
    
        ###Check for existence of our virtual network 
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Checking for VirtualNetworkSites node"
        Write-Debug "About to check for VirtualNetworkSites node"
    
        #Get the VirtualNetworkSites child of the VirtualNetworkConfiguration Node
        $SitesNode = $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.ChildNodes | Where-Object {$_.Name -eq "VirtualNetworkSites"}
    
        #Check if the VirtualNetworkSites node was found
        If ($SitesNode) {
    
            #Update comment
            Write-Verbose "$(Get-Date -f T) - VirtualNetworkSites node found"
    
            #Now check for whether VirtualNetworkSites node is empty
            If ($SitesNode.HasChildNodes -eq $False) {
    
                #Write that no existing DNS servers were found to screen
                Write-Verbose "$(Get-Date -f T) - No existing virtual network sites found"
    
                #Troubleshooting messages
                Write-Verbose "$(Get-Date -f T) - Adding virtual network site - $vNetName"
                Write-Debug "About to add virtual network site - $vNetName - to network configuration"
    
                #Create a template for the VirtualNetworkSites node
                $SitesEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites, $True)
                
                #Import the newly created template
                $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.ReplaceChild($SitesEntry, $SitesNode) | Out-Null
    
                    #Error handling
                    If (!$?) {
    
                        #Write Error and exit
                        Write-Error "Unable to replace VirtualNetworkSites node" -ErrorAction Stop
    
                    }   #End of If (!$?) 
                    Else {
    
                        #Troubleshooting message
                        Write-Verbose "$(Get-Date -f T) - VirtualNetworkSite - $vNetName - added to in-memory network configuration"

                        #Set the vNetConfig update flag to true so we know we have changes to commit later
                        $UpdatevNetConfig = $True
    
                    }   #End of Else (!$?)
                    
            }   #End of If ($SitesNode.HasChildNodes -eq $False)
            Else {
    
                #Write that we have found child nodes
                Write-Verbose "$(Get-Date -f T) - VirtualNetworkSites node has child nodes"

                #Troubleshooting messages
                Write-Verbose "$(Get-Date -f T) - Checking for $vNetName in child nodes"
                Write-Debug "About to check for $vNetName in child nodes"

                #Get a list of currently configured virtual network sites
                $vNetSites = $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.VirtualNetworkSite

                #Troubleshooting messages
                Write-Verbose "$(Get-Date -f T) - Checking for virtual network site conflict"
                Write-Debug "About to check for virtual network site conflict"

                #Loop through the DNS server entries
                $vNetSites | ForEach-Object {

                    #See if we have the vNetSite name already in use
                    If ($_.Name -eq $vNetName) {
                        
                        #Write confirmation that our virtual network site already exists
                        Write-Error "$vNetName already exists - please investigate" -ErrorAction Stop

                    }   #End of If ($_.Name -eq $vNetName)

                }   #End of ForEach-Object


                #Troubleshooting messages
                Write-Verbose "$(Get-Date -f T) - No conflicts found"
                Write-Verbose "$(Get-Date -f T) - Adding virtual network site - $vNetName"
                Write-Debug "About to add virtual network site - $vNetName - to network configuration"

                #Create a template for an entry to the DNSservers node
                $vNetSiteEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.VirtualNetworkSite, $True)

                #Add the template to out copy of the vNetConfig in memory
                $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.AppendChild($vNetSiteEntry) | Out-Null

                    #Error handling
                    If (!$?) {

                        #Write Error and exit
                        Write-Error "Unable to append virtual network site - $vNetName" -ErrorAction Stop

                    }   #End of If (!$?) 
                    Else {

                        #Troubleshooting message
                        Write-Verbose "Virtual network site - $vNetName - added to in-memory network configuration"

                        #Set the vNetConfig update flag to true so we know we have changes to commit later
                        $UpdatevNetConfig = $True

                    }   #End of Else (!$?)

            }   #End of Else ($SitesNode.HasChildNodes -eq $False)
    
        }   #End of If ($SitesNode)
        Else {
    
            #Write that VirtualNetworkSites node not found to screen
            Write-Verbose "$(Get-Date -f T) - VirtualNetworkSites node not found"
    
            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Adding virtual network site - $vNetName"
            Write-Debug "About to add virtual network site - $vNetName - to network configuration"
    
            #Create a template for the VirtualNetworkSites node
            $SitesEntry = $vNetConfig.ImportNode($NetCfg.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites, $True)
            
            #Import the newly created template
            $vNetConfig.NetworkConfiguration.VirtualNetworkConfiguration.AppendChild($SitesEntry) | Out-Null
    
                #Error handling
                If (!$?) {
    
                    #Write Error and exit
                    Write-Error "Unable to add VirtualNetworkSites to VirtualNetworkConfiguration node" -ErrorAction Stop
    
                }   #End of If (!$?) 
                Else {
    
                    #Troubleshooting message
                    Write-Verbose "$(Get-Date -f T) - VirtualNetworkSite - $vNetName - added to in-memory network configuration"

                    #Set the vNetConfig update flag to true so we know we have changes to commit later
                    $UpdatevNetConfig = $True
    
                }   #End of Else (!$?)
    
        }   #End of Else ($SitesNode)
    
        #Check whether we have any configuration to update
        If ($UpdatevNetConfig) {

            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Exporting updated in-memory configuration to $NetCfgFile"
            Write-Debug "About to export updated in-memory configuration to $NetCfgFile"

            #Copy the in-memory config back to a file
            Set-Content -Value $vNetConfig.InnerXml -Path $NetCfgFile

                #Error handling
                If (!$?) {
    
                    #Write Error and exit
                    Write-Error "Unable to export updated vNet configuration to $NetCfgFile" -ErrorAction Stop
    
                }   #End of If (!$?) 
                Else {
    
                    #Troubleshooting message
                    Write-Verbose "$(Get-Date -f T) - Exported updated vNet configuration to $NetCfgFile"
    
                }   #End of Else (!$?)


            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Creating $vNetName virtual network from updated config file"
            Write-Debug "About to create $vNetName virtual network from updated config file"
    
            #Create a new virtual network from the config file
            Set-AzureVNetConfig -ConfigurationPath $NetCfgFile -ErrorAction SilentlyContinue | Out-Null
    
                #Error handling
                If (!$?) {
    
                    #Write Error and exit
                    Write-Error "Unable to create $vNetName virtual network" -ErrorAction Stop
    
                }   #End of If (!$?) 
                Else {
    
                    #Troubleshooting message
                    Write-Verbose "$(Get-Date -f T) - $vNetName virtual network successfully created"
    
                }   #End of Else (!$?)


        }   #End of If ($UpdatevNetConfig)
        Else {

            #Troubleshooting message
            Write-Verbose "$(Get-Date -f T) - vNet config does not need updating"


        }   #End of Else ($UpdatevNetConfig)
    
    }   #End of Else (!$vNetConfig)

}   #End of Function Update-AzurevNetConfig


##########################################################################################################

###############################
## FUNCTION 3 - Create-AzureVM
###############################

#Creates a VM using a supplied VM config

Function Create-AzureVM {

Param(
      #The name of the cloud service, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      [String]$ServicePrefix,
      
      #The name used to prefix all build items, e.g. FARRCLOUD
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$VMName,

      #The data centre location of the build items
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      [String]$Location,

      #The virtual network name
      [parameter(Mandatory,Position=4)]
      [ValidateNotNullOrEmpty()]
      [String]$vNetName,

      #The virtual machine config
      [parameter(Mandatory,Position=5)]
      [ValidateNotNullOrEmpty()]
      $VMConfig,

      #The Azure DNS object
      [parameter(Mandatory,Position=6)]
      [ValidateNotNullOrEmpty()]
      $AzureDns
      )

#If the creation of the first DC failed stop processing
Switch -Wildcard ($VMName) {

    #Check for the first DC
    "*DC01" {
        
        #Create a new VM and new cloud service
        New-AzureVM -ServiceName $ServicePrefix `
                    -Location $Location `
                    -VNetName $vNetName `
                    -VMs $VMConfig `
                    -DnsSettings $AzureDns `
                    -WaitForBoot | Out-Null

    }  #End of "*DC01"


    #Check for member servers
    "*MEM*" {
        
        #Create a new VM and don't wait for reboot
        New-AzureVM -ServiceName $ServicePrefix -VMs $VMConfig | Out-Null

    }   #End of "*MEM*"


    #Check for clients
    "*CLI*" {
        
        #Create a new VM and don't wait for reboot
        New-AzureVM -ServiceName $ServicePrefix -VMs $VMConfig | Out-Null

    }   #End of "*CLI*"


    Default {

        #Create a new VM and wait for reboot
        New-AzureVM -ServiceName $ServicePrefix -VMs $VMConfig -WaitForBoot | Out-Null

    }   #End of Default


}   #End of Switch ($VMName)       
             
    
    #Error handling
    If (!$?) {

        #Write Error and exit
        Write-Verbose "$(Get-Date -f T) - Something went wrong with the VM creation - we may still be ok though..."

    }   #End of If (!$?) 
    Else {

        #Troubleshooting message
        Write-Verbose "$(Get-Date -f T) - VM created successfully"

    }   #End of Else (!$?)


#Troubleshooting messagesWrite-Verbose "$(Get-Date -f T) - Checking $VMName status"
Write-Debug "About to check $VMName status" #Get the VM status$VMService = Get-AzureVM -ServiceName $ServicePrefix -Name $VMName -ErrorAction SilentlyContinue        #Check we've got status information    If ($VMService) {

        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - $VMName status verified"


    }   #End of If ($VMService)
    Else {

        #If the creation of the first DC failed stop processing
        If ($VMName -like "*DC01") {
        
            #Write error and exit
            Write-Error "Failed to obtain staus for first VM - $VMName" -ErrorAction Stop

        }   #End of If ($VMName -like "*DC01")
        Else {

            #Write error and carry on 
            Write-Error "Failed to obtain status for VM... exiting build function"

        }   #End of Else ($VMName -like "*DC01")

    }   #End of ($VMService)

}   #End of Function Create-AzureVM


##########################################################################################################

##############################
## FUNCTION 4 - Import-VMCert
##############################

#Imports a VM WinRM management cert

Function Import-VMWinRmCert {

Param(
      #The name of the cloud service, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      [String]$ServicePrefix,
      
      #The virtual machine name
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$VMName
      )

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Obtaining thumbprint of WinRM cert for $VMName"
Write-Debug "About to obtain thumbprint of WinRM cert for $VMName"

#Get the thumbprint of the VM's WinRM cert
$WinRMCert = (Get-AzureVM -ServiceName $ServicePrefix -Name $VMName).VM.DefaultWinRMCertificateThumbprint

    If ($WinRMCert) {
    
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Saving $ServicePrefix Azure certificate data to cer file"
        Write-Debug "About to save $ServicePrefix Azure certificate data to cer file"

        #Get a certificare object for the VM's service and save it's data to a .cer file
        (Get-AzureCertificate -ServiceName $ServicePrefix -Thumbprint $WinRMCert -ThumbprintAlgorithm sha1).Data | 
        Out-File "$SourceParent\$ServicePrefix.cer"

            #Error handling
            If ($?) {

                #Troubleshooting message
                Write-Verbose "$(Get-Date -f T) - $ServicePrefix Azure certificate exported to cer file"
                Write-Verbose "$(Get-Date -f T) - Importing $ServicePrefix Azure certificate to Cert:\localmachine\root"
                Write-Debug "About to import $ServicePrefix Azure certificate to Cert:\localmachine\root"

                #Import the certifcate into the local computer's root store
                Import-Certificate -FilePath "$SourceParent\$ServicePrefix.cer" -CertStoreLocation "Cert:\localmachine\root" -ErrorAction SilentlyContinue |
                Out-Null

                #Error handling
                If ($?) {

                    #Troubleshooting message
                    Write-Verbose "$(Get-Date -f T) - $ServicePrefix Azure certificate imported to local computer root store"


                }   #End of If ($?)
                Else {

                    #Write Error
                    Write-Error "Unable to import certificate to local computer root store - script remoting won't be possible for $ServicePrefix"

                }   #End of 

            }   #End of If (!$?) 
            Else {

                #Write Error
                Write-Error "Unable to export certificate to cer file - script remoting won't be possible for $ServicePrefix"

            }   #End of Else (!$?)


    }   #End of If ($WinRMCert)
    Else {

        #Write Error
        Write-Error "Unable to obtain WinRM certificate thumbprint - script remoting won't be possible for $ServicePrefix"

    }   #Else($WinRMCert)


}   #End of Function Import-VMWinRMCert


##########################################################################################################

###################################
## FUNCTION 5 - Create-VmPsSession
###################################

#Create a PS session to a remote host

Function Create-VmPsSession {

Param(
      #The name of the cloud service, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      [String]$ServicePrefix,

      #The virtual machine name
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$VMName,

      #The admin user account 
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminUser,

      #The admin user password
      [parameter(Mandatory,Position=4)]
      [ValidateNotNullOrEmpty()]
      $SecurePassword
      )

#Get the WinRM URI of the host
$WinRmUri = Get-AzureWinRMUri -ServiceName $ServicePrefix -Name $VMName    #Error handling
    If ($WinRmUri) {

        #Write details of current subscription to screen
        Write-Verbose "$(Get-Date -f T) - WINRM connection URI obtained"

        #Create a credential object to pass to New-PSSession
        $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $AdminUser,$SecurePassword

            #Error handling
            If ($Credential) {

                #Write credential object confirmation to screen
                Write-Verbose "$(Get-Date -f T) - Credential object created"

                #Create a new remote PS Session to pass commands to
                $VMSession = New-PSSession -ConnectionUri $WinRmUri.AbsoluteUri -Credential $Credential

                    #Error handling
                    If ($VMSession) {

                        #Write remote PS session confirmation to screen
                        Write-Verbose "$(Get-Date -f T) - Remote PS session established"
                        Return $VMSession

                    }   #End of If ($VMSession)
                    Else {

                        #Write Error and exit
                        Write-Error "Unable to create remote PS session" 

                    }   #End of Else ($VMSession)


            }   #End of If ($Credential)
            Else {

                #Write Error and exit
                Write-Error "Unable to create credential object" 

            }   #End of Else ($Credential)


    }   #End of If ($WinRmUri)
    Else {

        #Write Error and exit
        Write-Error "Unable to obtain a valid WinRM URI" 

    }   #End of Else ($WinRmUri)


}   #End of Function Create-VmPsSession


##########################################################################################################


################################
## FUNCTION 6 - Add-DcDataDrive
################################

#Configure the data drive on the DC

Function Add-DcDataDrive {

Param(
      #The PS Session to connect to
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      $VMSession
      )

#We've added an additional disk to store AD's DB, logs and SYSVOl - time to initialize, partition and format the drive
$ConfigureDisk = Invoke-Command -Session $VMSession -ScriptBlock {Get-Disk | Where-Object {$_.PartitionStyle -eq "RAW"} | 
                                                                  Initialize-Disk -PartitionStyle MBR -PassThru |
                                                                  New-Partition -UseMaximumSize -DriveLetter Z | 
                                                                  Format-Volume -FileSystem NTFS -Force -Confirm:$False}
    #Error handling
    If ($ConfigureDisk) {
    
        #Write remote PS session confirmation to screen
        Write-Verbose "$(Get-Date -f T) - Additional data disk successfully configured"
    
    }   #End of If ($VMSession)
    Else {
    
        #Write Error and exit
        Write-Error "Unable to configure additional data disk" 
    
    }   #End of Else ($VMSession)


}   #End of Function Add-DcDataDrive



##########################################################################################################

####################################
## FUNCTION 7 - Create-AzureServer
####################################

#Creates member servers

Function Create-AzureServer {

Param(
      #The name used to prefix all build items, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateLength(2,12)]
      [String]$ServicePrefix,

      #The admin user account 
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminUser,

      #The admin password
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminPassword,

      #The secure password
      [parameter(Position=4)]
      [ValidateNotNullOrEmpty()]
      $SecurePassword,

      #The FQDN of the Active Directory forest
      [parameter(Position=5)]
      [String]$ForestFqdn,

      #The NetBios name of the Active Directory domain to create
      [parameter(Position=6)]
      [String]$Domain,

      #Credentials for the dcpromo
      [parameter(Position=7)]
      $DomainCredential,

      #The number of DCs to spin up
      [parameter(Position=8)]
      [ValidateRange(1,4)]
      [Single]$ServerCount,

      #Whether we're promoting a DC
      [Switch]
      $IsDC
      )

    #Create a loop to process each additional server needed
    for ($i = 1; $i -le $ServerCount; $i++) {
   
        #Set VM size
        $Size = "Small"


        #Check whether we're creating a DC and set the VMConfig accordingly
        If ($IsDc) {

            #Set VM name
            $VMName = "$($ServicePrefix)DC0$($i + 1)"
        
            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Commissioning domain controller - $VMName"
            Write-Debug "About to commission domain controller - $VMName"

            #Create a VM config
            $VMConfig = New-AzureVMConfig -Name $VMName -InstanceSize $Size -ImageName $Image |
                        Add-AzureProvisioningConfig -WindowsDomain -AdminUsername $AdminUser -Password $AdminPassword -JoinDomain $ForestFqdn `
                                                    -Domain $Domain -DomainUserName $AdminUser -DomainPassword $AdminPassword |
                        Add-AzureDataDisk -CreateNew -DiskSizeInGB 20 -DiskLabel "$($ServicePrefix)0$($i + 1)_Data" -LUN 0 -HostCaching None |
                        Set-AzureSubnet -SubnetNames "$($ServicePrefix)Subnet1" |
                        Set-AzureStaticVNetIP -IPAddress "10.0.$($ClassCSubnetNumber).$($i + 4)"

        }   #End of If ($IsDc)
        Else {

            #Set VM name
            $VMName = "$($ServicePrefix)MEM0$i"

            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Commissioning member server - $VMName"
            Write-Debug "About to commission member server - $VMName"


            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Creating VM config"
            Write-Debug "About to create VM config"
        
            #Create a VM config
            $VMConfig = New-AzureVMConfig -Name $VMName -InstanceSize $Size -ImageName $Image |
                        Add-AzureProvisioningConfig -WindowsDomain -AdminUsername $AdminUser -Password $AdminPassword -JoinDomain $ForestFqdn `
                                                    -Domain $Domain -DomainUserName $AdminUser -DomainPassword $AdminPassword |
                        Set-AzureSubnet -SubnetNames "$($ServicePrefix)Subnet1"

        }   #End of If ($IsDc)


        #Error handling
        If ($VMConfig) {
        
            #Write details of current subscription to screen
            Write-Verbose "$(Get-Date -f T) - VMConfig created"
        
        }   #End of If ($Image)
        Else {
        
            #Write Error and exit
            Write-Error "Unable to create VM config" 
        
        }   #End of Else ($Image)
        
        
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Creating VM $VMName"
        Write-Debug "About to create $VMName"
        
        #Call Create-AzureVM function
        Create-AzureVM -ServicePrefix $ServicePrefix -VMName $VMName -Location $Location -vNetName $vNetName -VMConfig $VMConfig -AzureDns $AzureDns

    
        #Perform additional actions for our DC
        If ($IsDC) {

            #Troubleshooting messages            Write-Verbose "$(Get-Date -f T) - Creating PS Remoting session on $VMName" 
            Write-Debug "About to create PS Remoting session on $VMName" 
                        #Call Create-VmPsSession function            $DCSession = Create-VmPsSession -Service $ServicePrefix -VMName $VMName -AdminUser $AdminUser -SecurePassword $SecurePassword                                    #Troubleshooting messages            Write-Verbose "$(Get-Date -f T) - Configure additional data drive on $VMName" 
            Write-Debug "About to configure additional data drive on $VMName"                         #Call Add-DcDataDrive function            Add-DcDataDrive -VMSession $DCSession
            
            
            #Troubleshooting messages            Write-Verbose "$(Get-Date -f T) - Configure AD DS binaries on $VMName" 
            Write-Debug "About to configure AD DS binaries on $VMName" 
            
            #Now let's install the Active Directory domain services binaries
            $ConfigureBinaries = Invoke-Command -Session $DCSession -ScriptBlock {Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools}
            
                #Error handling
                If ($ConfigureBinaries) {
            
                    #Write details of current subscription to screen
                    Write-Verbose "$(Get-Date -f T) - AD DS binaries added to $VMName"
            
                }   #End of If ($ConfigureBinaries)
                Else {
            
                    #Write Error and exit
                    Write-Error "Unable to install AD DS binaries on $VMName" 
            
                }   #End of Else ($ConfigureBinaries)
            
            
            #Troubleshooting messages            Write-Verbose "$(Get-Date -f T) - Adding $VMName to $ForestFqdn" 
            Write-Debug "About to add $VMName to $ForestFqdn" 
            
            #Now let's promote the DC
            Invoke-Command -Session $DCSession -ArgumentList $ForestFqdn,$SecurePassword,$DomainCredential -ScriptBlock { 
                Param(
                  #The forest name
                  [parameter(Mandatory,Position=1)]
                  [ValidateNotNullOrEmpty()]
                  $ForestFqdn,
            
                  #The DSRM password
                  [parameter(Mandatory,Position=2)]
                  [ValidateNotNullOrEmpty()]
                  $SecurePassword,

                  #The Domain credentials
                  [parameter(Mandatory,Position=3)]
                  [ValidateNotNullOrEmpty()]
                  $DomainCredential
                  )
                
                #Execute the dc promotion cmdlet
                Install-ADDSDomainController -Credential $DomainCredential `
                                             -CreateDnsDelegation:$False `
                                             -DatabasePath "Z:\Windows\NTDS" `
                                             -DomainName $ForestFqdn `
                                             -InstallDns:$True `
                                             -LogPath "Z:\Windows\NTDS" `
                                             -NoRebootOnCompletion:$False `
                                             -SysvolPath "Z:\Windows\SYSVOL" `
                                             -Force:$True `
                                             -SafeModeAdministratorPassword $SecurePassword `
                                             -SkipPreChecks | Out-Null
            
            }   #End of -ScriptBlock
            

            #Troubleshooting messages            Write-Verbose "$(Get-Date -f T) - Verifying status of $VMName" 
            Write-Debug "About to verify status of $VMName" 

            #Get VM status
            $VMStatus = Get-AzureVM -ServiceName $ServicePrefix -Name $VMName -ErrorAction SilentlyContinue
            
            #Use a while loop to wait until 'ReadyRole' is achieved            While ($VMStatus.InstanceStatus -ne "ReadyRole") {
            
              #Write progress to verbose, sleep and check again  
              Start-Sleep -Seconds 60
              $VMStatus = Get-AzureVM -ServiceName $ServicePrefix -Name $VMName -ErrorAction SilentlyContinue
                        }   #End of While ($VMStatus.InstanceStatus -ne "ReadyRole")
            
            
            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - InstanceStatus verification - $($VMStatus.InstanceStatus)"    
            

            #Troubleshooting messages
            Write-Verbose "$(Get-Date -f T) - Removing PS Remoting session on $VMName" 
            Write-Debug "About to remove PS Remoting session on $VMName" 
            
            #Remove the session
            Remove-PSSession $DCSession -ErrorAction SilentlyContinue
            
                #Error handling
                If (!$?) {
            
                    #Write Error and exit
                    Write-Error "Unable to remove PS Remoting session on $VMName"
            
                }   #End of If (!$?) 
                Else {
            
                    #Troubleshooting message
                    Write-Verbose "$(Get-Date -f T) - $VMName PS Remoting session successfully removed"
            
                }   #End of Else (!$?) 


        }   #End of If ($IsDC)

        
    }   #End of for ($i = 1; $i -le $ServerCount; $i++)


}   #End of Function Create-AzureServer


##########################################################################################################

###################################
## FUNCTION 8 - Create-AzureClient
###################################

#Creates member servers

Function Create-AzureClient {

Param(
      #The name used to prefix all build items, e.g. IANCLOUD
      [parameter(Mandatory,Position=1)]
      [ValidateLength(2,12)]
      [String]$ServicePrefix,

      #The admin user account 
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminUser,

      #The admin password
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      [String]$AdminPassword,

      #The secure password
      [parameter(Position=4)]
      [ValidateNotNullOrEmpty()]
      $SecurePassword,

      #The FQDN of the Active Directory forest
      [parameter(Position=5)]
      [String]$ForestFqdn,

      #The NetBios name of the Active Directory domain
      [parameter(Position=6)]
      [String]$Domain,

      #Credentials for the dcpromo
      [parameter(Position=7)]
      $DomainCredential,

      #The number of DCs to spin up
      [parameter(Position=8)]
      [ValidateRange(1,4)]
      [Single]$ClientCount,

      #The type of client, e.g. Win7 or Win8
      [parameter(Position=9)]
      [ValidateSet("Win7", "Win8", "Win10")]
      [String]$ClientType
      )


    #Set VM size
    $Size = "Small"
    
    #Obtain client image to be used
    If ($ClientType -eq "Win7") {
    
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Obtaining the latest Windows 7 image"
        Write-Debug "About to obtain the latest Windows 7 image"
    
        #Get the latest Windows 7 OS image
        $Image = (Get-AzureVMImage | 
                  Where-Object {$_.Label -like "Windows 7 Enterprise*"} | 
                  Sort-Object PublishedDate -Descending)[0].ImageName
    
            #Error handling
            If ($Image) {
    
                #Write details of current subscription to screen
                Write-Verbose "$(Get-Date -f T) - Image found - $($Image)"
    
            }   #End of If ($Image)
            Else {
    
                #Write Error and exit
                Write-Error "Unable to obtain valid OS image"

                #Exit the function
                Exit
    
            }   #End of Else ($Image)
    
    
    }   #End of If ($ClientType -eq "Win7")

    Elseif ($ClientType -eq "Win8") {
    
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Obtaining the latest Windows 8 image"
        Write-Debug "About to obtain the latest Windows 8 image"
    
        #Get the latest Windows 8 OS image
        $Image = (Get-AzureVMImage | 
                  Where-Object {$_.Label -like "Windows 8.1 Enterprise*"} | 
                  Sort-Object PublishedDate -Descending)[0].ImageName
    
            #Error handling
            If ($Image) {
    
                #Write details of current subscription to screen
                Write-Verbose "$(Get-Date -f T) - Image found - $($Image)"
    
            }   #End of If ($Image)
            Else {
    
                #Write Error and exit
                Write-Error "Unable to obtain valid OS image"

                #Exit the function
                Exit
    
            }   #End of Else ($Image)

    
    }   #End of Elseif ($ClientType -eq "Win8")

    Else {

        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Obtaining the latest Windows 10 image"
        Write-Debug "About to obtain the latest Windows 10 image"
    
        #Get the latest Windows 8 OS image
        $Image = (Get-AzureVMImage | 
                  Where-Object {$_.Label -like "Windows 10 Enterprise (x64)*"} | 
                  Sort-Object PublishedDate -Descending)[0].ImageName
    
            #Error handling
            If ($Image) {
    
                #Write details of current subscription to screen
                Write-Verbose "$(Get-Date -f T) - Image found - $($Image)"
    
            }   #End of If ($Image)
            Else {
    
                #Write Error and exit
                Write-Error "Unable to obtain valid OS image"

                #Exit the function
                Exit
    
            }   #End of Else ($Image)


    }   #End of Else ($ClientType -eq "Win8")


    #Create a loop to process each additional client needed
    for ($i = 1; $i -le $ClientCount; $i++) {
 

        #Set VM name
        $VMName = "$($ServicePrefix)CLI$(($ClientType).SubString(3))0$i"
        
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Commissioning client - $VMName"
        Write-Debug "About to commission client - $VMName"
        
        
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Creating VM config"
        Write-Debug "About to create VM config"
        
        #Create a VM config
        $VMConfig = New-AzureVMConfig -Name $VMName -InstanceSize $Size -ImageName $Image |
                    Add-AzureProvisioningConfig -WindowsDomain -AdminUsername $AdminUser -Password $AdminPassword -JoinDomain $ForestFqdn `
                                                -Domain $Domain -DomainUserName $AdminUser -DomainPassword $AdminPassword |
                    Set-AzureSubnet -SubnetNames "$($ServicePrefix)Subnet1"
        

        #Error handling
        If ($VMConfig) {
        
            #Write details of current subscription to screen
            Write-Verbose "$(Get-Date -f T) - VMConfig created"
        
        }   #End of If ($Image)
        Else {
        
            #Write Error and exit
            Write-Error "Unable to create VM config" 
        
        }   #End of Else ($Image)
        
        
        #Troubleshooting messages
        Write-Verbose "$(Get-Date -f T) - Creating VM $VMName"
        Write-Debug "About to create $VMName"
        
        #Call Create-AzureVM function
        Create-AzureVM -ServicePrefix $ServicePrefix -VMName $VMName -Location $Location -vNetName $vNetName -VMConfig $VMConfig -AzureDns $AzureDns

        
    }   #End of for ($i = 1; $i -le $ClientCount; $i++)


}   #End of Function Create-AzureClient


##########################################################################################################

####################
## MAIN SCRIPT BODY
####################

##############################
#Stage 1 - Check Connectivity
##############################

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Checking Azure connectivity"
Write-Debug "About to check Azure connectivity"

#Check we have Azure connectivity
$Subscription = Get-AzureSubscription -Current 

    #Error handling
    If ($Subscription) {

        #Write details of current subscription to screen
        Write-Verbose "$(Get-Date -f T) - Current subscription found - $($Subscription.SubscriptionName)"

    }   #End of If ($Subscription)
    Else {

        #Write Error and exit
        Write-Error "Unable to obtain current Azure subscription details" -ErrorAction Stop

    }   #End of Else ($Subscription)



##############################
#Stage 2 - Create NetCfg File
##############################

#Variable for NetCfg file
$SourceParent = (Get-Location).Path
$NetCfgFile = "$SourceParent\$($ServicePrefix)_vNet.netcfg"

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Creating vNet config file"
Write-Debug "About to create the vNet config file"

#Use the Create-AzurevNetCfgFile function to create the NetCfg XML file used to seed the new Azure virtual network
Create-AzurevNetCfgFile -ServicePrefix $ServicePrefix -Location $Location -NetCfgFile $NetCfgFile



##################################
#Stage 3 - Create Virtual Network
##################################

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Creating Azure DNS object"
Write-Debug "About to create Azure DNS object"

#First, create an object representing the DNS server for this vNet (this is used with the -DnsSettings parameter of New-AZureVM)
$AzureDns = New-AzureDns -IPAddress "10.0.$($ClassCSubnetNumber).4" -Name "$($ServicePrefix)DC01" -ErrorAction SilentlyContinue 

  #Error handling
  If ($AzureDns) {

      #Troubleshooting message
      Write-Verbose "$(Get-Date -f T) - DNS object successfully created"

  }   #End of If ($AzureDns) 
  Else {

      #Write Error and exit
      Write-Error "Unable to create DNS object" -ErrorAction Stop

  }   #End of Else ($AzureDns)


#Set virtual network name
$vNetName = "$($ServicePrefix)vNet"

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Checking for existing vNet config"
Write-Debug "About to check for existing vNet config"

#Call Update-AzurevNetConfig function to create or update the VNet configuration
Update-AzurevNetConfig -vNetName $vNetName -NetCfgFile $NetCfgFile


##################################
#Stage 4 - Create Storage Account
##################################

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Creating $($ServicePrefix) storage account"
Write-Debug "About to create $($ServicePrefix) storage account"

#Create a storage account name, containing lower-case letters and numbers, that's unique to Azure
$StorageAccount = "$($ServicePrefix.ToLower())$(Get-Random)sa"

#Use the New-AzureStorageAccount cmdlet to set-up a new storage account
New-AzureStorageAccount -StorageAccountName $StorageAccount -Location $Location -ErrorAction SilentlyContinue | Out-Null

    #Error handling
    If (!$?) {

        #Write Error and exit
        Write-Error "Unable to create storage account - $StorageAccount" -ErrorAction Stop

    }   #End of If (!$?) 
    Else {

        #Troubleshooting message
        Write-Verbose "$(Get-Date -f T) - $StorageAccount storage account successfully created"

    }   #End of Else (!$?)


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Referencing the new storage account"
Write-Debug "About to reference the new storage account"

#Reference the new storage account in preparation for the creation of VMs
Set-AzureSubscription -SubscriptionName ($Subscription).SubscriptionName -CurrentStorageAccount $StorageAccount -ErrorAction SilentlyContinue

    #Error handling
    If (!$?) {

        #Write Error and exit
        Write-Error "Unable to reference new storage account" -ErrorAction Stop

    }   #End of If (!$?) 
    Else {

        #Troubleshooting message
        Write-Verbose "$(Get-Date -f T) - New storage account successfully referenced"

    }   #End of Else (!$?)



######################################
#Stage 5 - Create First DC and Forest
######################################

#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Obtaining the latest Windows Server 2012 R2 image"
Write-Debug "About to obtain the latest Windows Server 2012 R2 image"

#Get the latest Windows Server 2012 R2 Datacenter OS image
$Image = (Get-AzureVMImage | 
          Where-Object {$_.Label -like "Windows Server 2012 R2 Datacenter*"} | 
          Sort-Object PublishedDate -Descending)[0].ImageName

    #Error handling
    If ($Image) {

        #Write details of current subscription to screen
        Write-Verbose "$(Get-Date -f T) - Image found - $($Image)"

    }   #End of If ($Image)
    Else {

        #Write Error and exit
        Write-Error "Unable to obtain valid OS image " -ErrorAction Stop

    }   #End of Else ($Image)


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Commissioning first DC"
Write-Debug "About to commission first DC"

#Set VM specific variables (Name / Instance Size)
$VMName = "$($ServicePrefix)DC01"
$Size = "Small"


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Creating VM config"
Write-Debug "About to create VM config"

#Create a VM config
$VMConfig = New-AzureVMConfig -Name $VMName -InstanceSize $Size -ImageName $Image |
            Add-AzureProvisioningConfig -Windows -AdminUsername $AdminUser -Password $AdminPassword |
            Add-AzureDataDisk -CreateNew -DiskSizeInGB 20 -DiskLabel "$($ServicePrefix)DC01_Data" -LUN 0 -HostCaching None |
            Set-AzureSubnet -SubnetNames "$($ServicePrefix)Subnet1" |
            Set-AzureStaticVNetIP -IPAddress "10.0.$($ClassCSubnetNumber).4"

    #Error handling
    If ($VMConfig) {

        #Write details of current subscription to screen
        Write-Verbose "$(Get-Date -f T) - VMConfig created"

    }   #End of If ($Image)
    Else {

        #Write Error and exit
        Write-Error "Unable to create VM config" -ErrorAction Stop

    }   #End of Else ($Image)


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Creating VM $VMName"
Write-Debug "About to create $VMName"

#Call Create-AzureVM function
Create-AzureVM -ServicePrefix $ServicePrefix -VMName $VMName -Location $Location -vNetName $vNetName -VMConfig $VMConfig -AzureDns $AzureDns


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Configuring certificate for PS Remoting access on $ServicePrefix"
Write-Debug "About to configure certificate for PS Remoting access on $ServicePrefix"

#Call Import-VMWinRMCert function
Import-VMWinRmCert -ServicePrefix $ServicePrefix -VMName $VMName


#Troubleshooting messagesWrite-Verbose "$(Get-Date -f T) - Creating PS Remoting session on $VMName" 
Write-Debug "About to create PS Remoting session on $VMName" 

#Convert password to a secure string
$SecurePassword = $AdminPassword | ConvertTo-SecureString -AsPlainText -Force

    #Error handling
    If ($SecurePassword) {

        #Write secure string confirmation to screen
        Write-Verbose "$(Get-Date -f T) - Admin password converted to a secure string"

     }   #End of If ($SecurePassword)
     Else {

        #Write Error and exit
        Write-Error "Unable to convert secure password" -ErrorAction Stop

    }   #End of Else ($SecurePassword)

#Call Create-VmPsSession function$DCSession = Create-VmPsSession -ServicePrefix $ServicePrefix -VMName $VMName -AdminUser $AdminUser -SecurePassword $SecurePassword#Troubleshooting messagesWrite-Verbose "$(Get-Date -f T) - Configure additional data drive on $VMName" 
Write-Debug "About to configure additional data drive on $VMName" #Call Add-DcDataDrive functionAdd-DcDataDrive -VMSession $DCSession


#Troubleshooting messagesWrite-Verbose "$(Get-Date -f T) - Configure AD DS binaries on $VMName" 
Write-Debug "About to configure AD DS binaries on $VMName" 

#Now let's install the Active Directory domain services binaries
$ConfigureBinaries = Invoke-Command -Session $DCSession -ScriptBlock {Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools}

    #Error handling
    If ($ConfigureBinaries) {

        #Write details of current subscription to screen
        Write-Verbose "$(Get-Date -f T) - AD DS binaries added to $VMName"

    }   #End of If ($ConfigureBinaries)
    Else {

        #Write Error and exit
        Write-Error "Unable to install AD DS binaries on $VMName" -ErrorAction Stop

    }   #End of Else ($ConfigureBinaries)


#Troubleshooting messagesWrite-Verbose "$(Get-Date -f T) - Configuring forest $ForestFqdn on $VMName" 
Write-Debug "About to configure forest $ForestFqdn on $VMName" 

#Now let's create the forest
Invoke-Command -Session $DCSession -ArgumentList $ForestFqdn,$Domain,$SecurePassword -ScriptBlock { 
    Param(
      #The forest name
      [parameter(Mandatory,Position=1)]
      [ValidateNotNullOrEmpty()]
      $ForestFqdn,

      #The domain NetBios name
      [parameter(Mandatory,Position=2)]
      [ValidateNotNullOrEmpty()]
      $Domain,

      #The DSRM password
      [parameter(Mandatory,Position=3)]
      [ValidateNotNullOrEmpty()]
      $SecurePassword
      )

    #Promote the new forest
    Install-ADDSForest -CreateDnsDelegation:$False `
                       -DatabasePath "Z:\Windows\NTDS" `
                       -DomainMode "Win2012R2" `
                       -DomainName $ForestFqdn `
                       -DomainNetbiosName $Domain `
                       -ForestMode "Win2012R2" `
                       -InstallDns:$True `
                       -LogPath "Z:\Windows\NTDS" `
                       -NoRebootOnCompletion:$False `
                       -SysvolPath "Z:\Windows\SYSVOL" `
                       -Force:$True `
                       -SafeModeAdministratorPassword $SecurePassword `
                       -SkipPreChecks | Out-Null

}   #End of -ScriptBlock


#Troubleshooting messagesWrite-Verbose "$(Get-Date -f T) - Verifying status of $VMName" 
Write-Debug "About to verify status of $VMName" 

#Get VM status
$VMStatus = Get-AzureVM -ServiceName $ServicePrefix -Name $VMName -ErrorAction SilentlyContinue

#Use a while loop to wait until 'ReadyRole' is achievedWhile ($VMStatus.InstanceStatus -ne "ReadyRole") {

  #Write progress to verbose, sleep and check again  
  Start-Sleep -Seconds 60
  $VMStatus = Get-AzureVM -ServiceName $ServicePrefix -Name $VMName -ErrorAction SilentlyContinue
}   #End of While ($VMStatus.InstanceStatus -ne "ReadyRole")


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - InstanceStatus verification - $($VMStatus.InstanceStatus)"  


#Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Removing PS Remoting session on $VMName" 
Write-Debug "About to remove PS Remoting session on $VMName" 

#Remove the sessions
Get-PSSession | Remove-PSSession -ErrorAction SilentlyContinue

    #Error handling
    If (!$?) {

        #Write Error and exit
        Write-Error "Unable to remove PS Remoting session on $VMName"

    }   #End of If (!$?) 
    Else {

        #Troubleshooting message
        Write-Verbose "$(Get-Date -f T) - $VMName PS Remoting session successfully removed"

    }   #End of Else (!$?)



#################################
#Stage 5 - Create Additional DCs
#################################

#Check whether we have to create any additional DCs
If ($DcCount -gt 1) {

    #Create a domain identity
    $CombinedUser = "$($Domain)\$($AdminUser)"

    #Create a domain credential for the dcpromo
    $DomainCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $CombinedUser,$SecurePassword

    #Call the Create-AzureServer function
    Create-AzureServer -ServicePrefix $ServicePrefix `
                       -AdminUser $AdminUser `
                       -AdminPassword $AdminPassword `
                       -SecurePassword $SecurePassword `
                       -ForestFqdn $ForestFqdn `
                       -Domain $Domain `
                       -DomainCredential $DomainCredential `
                       -ServerCount ($DcCount - 1) `
                       -IsDC


}   #End of If ($DcCount -gt 1)



#################################
#Stage 6 - Create Member Servers
#################################

#Check whether we have to create any member servers
If ($MemberCount -ge 1) {

    #Call the Create-AzureServer function
    Create-AzureServer -ServicePrefix $ServicePrefix `
                       -AdminUser $AdminUser `
                       -AdminPassword $AdminPassword `
                       -ForestFqdn $ForestFqdn `
                       -Domain $Domain `
                       -ServerCount $MemberCount

}   #End of ($MemberCount -ge 1)


##########################
#Stage 7 - Create Clients
##########################

#Check whether we have to create any W7 clients
If ($W7ClientCount -ge 1) {

    #Call the Create-AzureClient function for W7
    Create-AzureClient -ServicePrefix $ServicePrefix `
                       -AdminUser $AdminUser `
                       -AdminPassword $AdminPassword `
                       -ForestFqdn $ForestFqdn `
                       -Domain $Domain `
                       -ClientCount $W7ClientCount `
                       -ClientType Win7

}   #End of ($W7ClientCount -ge 1)


#Check whether we have to create any W8 clients
If ($W8ClientCount -ge 1) {

    #Call the Create-AzureClient function for W8
    Create-AzureClient -ServicePrefix $ServicePrefix `
                       -AdminUser $AdminUser `
                       -AdminPassword $AdminPassword `
                       -ForestFqdn $ForestFqdn `
                       -Domain $Domain `
                       -ClientCount $W8ClientCount `
                       -ClientType Win8

}   #End of ($W8ClientCount -ge 1)


#Check whether we have to create any W10 clients
If ($W10ClientCount -ge 1) {

    #Call the Create-AzureClient function for W10
    Create-AzureClient -ServicePrefix $ServicePrefix `
                       -AdminUser $AdminUser `
                       -AdminPassword $AdminPassword `
                       -ForestFqdn $ForestFqdn `
                       -Domain $Domain `
                       -ClientCount $W10ClientCount `
                       -ClientType Win10

}   #End of ($W8ClientCount -ge 1)


###############################
#Stage 8 - That's all folks...
###############################

##Troubleshooting messages
Write-Verbose "$(Get-Date -f T) - Finished creating $ForestFqdn forest in Microsoft Azure!"
Write-Verbose "$(Get-Date -f T) - Have a splendid day $([char]2) ..."


##########################################################################################################