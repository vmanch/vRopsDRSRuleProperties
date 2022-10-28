#Powershell collector script for DRS rules and pushing the results into vROPS.
#v1.0 vMan.ch, 15.11.2019 - Initial Version
#v1.1 vMan.ch, 18.03.2020 - Added logging, moved a loop, defined strings.
#v1.2 vMan.ch, 19.03.2020 - Added Member counts as a new metric.
#v1.3 vMan.ch, 20.10.2022 - Switch to token based auth and fixed DRSVM2HOSTRule

# Example Usage
# .\vCenterDRS2vROPSImporter.ps1 -vCenter 'vcsa.vman.ch' -vCenterUser 'administrator@vman.ch' -vCenterPassword 'P@ssw0rd123!' -vRopsAddress 'vropsa01.vman.ch' -vRopsUser 'admin' -vRopsPassword 'P@ssw0rd123!' -ImportType 'Full'

param
(
[Array]$vCenter,
[String]$vCenterUser,
[String]$vCenterPassword,
[String]$vRopsAddress,
[String]$vRopsUser,
[String]$vRopsPassword,
[String]$ImportType
)

#OtherVars
$vCenterCred = New-Object System.Management.Automation.PSCredential -ArgumentList $vCenterUser, $(ConvertTo-SecureString $vCenterPassword -AsPlainText -Force)
$vRopsCred = New-Object System.Management.Automation.PSCredential -ArgumentList $vRopsUser, $(ConvertTo-SecureString $vRopsPass -AsPlainText -Force)
[DateTime]$NowDate = (Get-date)
[int64]$NowDateEpoc = (([DateTimeOffset]$($NowDate)).ToUniversalTime().ToUnixTimeMilliseconds())
$DRSVMRuleReport = @()
$DRSClusterGroupReport = @()
$DRSVM2HOSTRuleReport = @()
$ScriptPath = "C:\VMware\vRops\DRS\"
$RunDateTime = $NowDate.tostring("yyyyMMddHHmmss")
$LogFileLoc = $ScriptPath + '\Log\Logfile.log'


#Load vCenter Creds
if($vCenterCred){
    Write-Host "vCenter creds loaded"
}
else
{
    Write-Host "vCenter cred not selected, stop hammer time!"
    Exit
}

#Load vRops Creds
if($vRopsCred){
    Write-Host "vRops creds loaded"
}
else
{
    Write-Host "vROPs cred not selected, stop hammer time!"
    Exit
}

#Check / Create Log folder
if (Test-Path $ScriptPath\Log) {
    Write-Host "Folder Exists"
    # Perform Delete file from folder operation
}
else
{
    #PowerShell Create directory if not exists
    New-Item $ScriptPath\Log -ItemType Directory
    Write-Host "Folder Created successfully"
}

#Logging Function
Function Log([String]$message, [String]$LogType, [String]$LogFile){
    $date = Get-Date -UFormat '%m-%d-%Y %H:%M:%S'
    $message = $date + "`t" + $LogType + "`t" + $message
    $message >> $LogFile
}

#Log rotation function
Function Reset-Log 
{ 
    #function checks to see if file in question is larger than the paramater specified if it is it will roll a log and delete the oldes log if there are more than x logs. 
    param([string]$fileName, [int64]$filesize = 1mb , [int] $logcount = 5) 
     
    $logRollStatus = $true 
    if(test-path $filename) 
    { 
        $file = Get-ChildItem $filename 
        if((($file).length) -ige $filesize) #this starts the log roll 
        { 
            $fileDir = $file.Directory 
            $fn = $file.name #this gets the name of the file we started with 
            $files = Get-ChildItem $filedir | ?{$_.name -like "$fn*"} | Sort-Object lastwritetime 
            $filefullname = $file.fullname #this gets the fullname of the file we started with 
            #$logcount +=1 #add one to the count as the base file is one more than the count 
            for ($i = ($files.count); $i -gt 0; $i--) 
            {  
                #[int]$fileNumber = ($f).name.Trim($file.name) #gets the current number of the file we are on 
                $files = Get-ChildItem $filedir | ?{$_.name -like "$fn*"} | Sort-Object lastwritetime 
                $operatingFile = $files | ?{($_.name).trim($fn) -eq $i} 
                if ($operatingfile) 
                 {$operatingFilenumber = ($files | ?{($_.name).trim($fn) -eq $i}).name.trim($fn)} 
                else 
                {$operatingFilenumber = $null} 
 
                if(($operatingFilenumber -eq $null) -and ($i -ne 1) -and ($i -lt $logcount)) 
                { 
                    $operatingFilenumber = $i 
                    $newfilename = "$filefullname.$operatingFilenumber" 
                    $operatingFile = $files | ?{($_.name).trim($fn) -eq ($i-1)} 
                    write-host "moving to $newfilename" 
                    move-item ($operatingFile.FullName) -Destination $newfilename -Force 
                } 
                elseif($i -ge $logcount) 
                { 
                    if($operatingFilenumber -eq $null) 
                    {  
                        $operatingFilenumber = $i - 1 
                        $operatingFile = $files | ?{($_.name).trim($fn) -eq $operatingFilenumber} 
                        
                    } 
                    write-host "deleting " ($operatingFile.FullName) 
                    remove-item ($operatingFile.FullName) -Force 
                } 
                elseif($i -eq 1) 
                { 
                    $operatingFilenumber = 1 
                    $newfilename = "$filefullname.$operatingFilenumber" 
                    write-host "moving to $newfilename" 
                    move-item $filefullname -Destination $newfilename -Force 
                } 
                else 
                { 
                    $operatingFilenumber = $i +1  
                    $newfilename = "$filefullname.$operatingFilenumber" 
                    $operatingFile = $files | ?{($_.name).trim($fn) -eq ($i-1)} 
                    write-host "moving to $newfilename" 
                    move-item ($operatingFile.FullName) -Destination $newfilename -Force    
                } 
                     
            } 
 
                     
          } 
         else 
         { $logRollStatus = $false} 
    } 
    else 
    { 
        $logrollStatus = $false 
    } 
    $LogRollStatus 
}

#Take all certs.
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Function New-vRopsToken {
    [CmdletBinding()]param(
        [PSCredential]$credentialFile,
        [string]$vROPSServer
    )
                                
    if ($vROPSServer -eq $null -or $vROPSServer -eq '') {
        $vROPSServer = ""
    }

    $vROPSUser = $credentialFile.UserName
    $vROPSPassword = $credentialFile.GetNetworkCredential().Password

    if ("TrustAllCertsPolicy" -as [type]) {} else {
    add-type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@ 
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }

    $BaseURL = "https://" + $vROPsServer + "/suite-api/api/"
    $BaseAuthURL = "https://" + $vROPsServer + "/suite-api/api/auth/token/acquire"
    $Type = "application/json"

    $AuthJSON =
    "{
    ""username"": ""$vROPSUser"",
    ""password"": ""$vROPsPassword""
    }"

    Try { $vROPSSessionResponse = Invoke-RestMethod -Method POST -Uri $BaseAuthURL -Body $AuthJSON -ContentType $Type }
    Catch {
        $_.Exception.ToString()
        $error[0] | Format-List -Force
    }

    $vROPSSessionHeader = @{"Authorization"="vRealizeOpsToken "+$vROPSSessionResponse.'auth-token'.token 
    "Accept"="application/xml"}
    $vROPSSessionHeader.add("X-vRealizeOps-API-use-unsupported","true")
    return $vROPSSessionHeader
}

Function GetObject([String]$vRopsObjName, [String]$resourceKindKey, [String]$vRopsServer, $vRopsToken){

$vRopsObjName = $vRopsObjName -replace ' ','%20'

[xml]$Checker = Invoke-RestMethod -Method GET -Uri "https://$vRopsServer/suite-api/api/resources?resourceKind=$resourceKindKey&name=$vRopsObjName" -ContentType "application/xml" -Headers $vRopsToken

# Check if we get more than 1 result and apply some logic
    If ([Int]$Checker.resources.pageInfo.totalCount -gt '1') {

        $DataReceivingCount = $Checker.resources.resource.resourceStatusStates.resourceStatusState.resourceStatus -eq 'DATA_RECEIVING'

            If ($DataReceivingCount.count -gt 1){

            If ($Checker.resources.resource.ResourceKey.name -eq $vRopsObjName){

                ForEach ($Result in $Checker.resources.resource){

                    IF ($Result.resourceStatusStates.resourceStatusState.resourceStatus -eq 'DATA_RECEIVING'){



                    $CheckerOutput = New-Object PsObject -Property @{Name=$vRopsObjName; resourceId=$Result.identifier; resourceKindKey=$Result.resourceKey.resourceKindKey} 

                    Return $CheckerOutput
    
                    }   
                }

            }
            }
                                        
            Else 
            {

            ForEach ($Result in $Checker.resources.resource){

                IF ($Result.resourceStatusStates.resourceStatusState.resourceStatus -eq 'DATA_RECEIVING'){

                    $CheckerOutput = New-Object PsObject -Property @{Name=$vRopsObjName; resourceId=$Result.identifier; resourceKindKey=$Result.resourceKey.resourceKindKeY}

                    Return $CheckerOutput
    
                }   
            }
    }  
}
    else
    {
                                
    IF ($Checker.resources.resource.ResourceKey.name -eq $vRopsObjName ) {

        $CheckerOutput = New-Object PsObject -Property @{Name=$vRopsObjName; resourceId=$Checker.resources.resource.identifier; resourceKindKey=$Checker.resources.resource.resourceKey.resourceKindKey}

    }

    Return $CheckerOutput

    }
}


#cleanupLogFile
Reset-Log -fileName $LogFileLoc -filesize 10mb -logcount 5

Write-Host "Starting Script"
Log -Message "Starting Script" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

Write-Host "Generating vRops Token for $($vRopsCred.UserName)"
Log -Message "Generating vRops Token for $($vRopsCred.UserName)" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

#Generate Token
$vRopsAdminToken = New-vRopsToken $vRopsCred $vRopsAddress

ForEach ($VC in $vCenter){


Write-Host "Connecting to $VC with credentials $($vCenterCred.UserName)"
Log -Message "Connecting to $VC with credentials $creds" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

Connect-VIServer -server $VC -Credential $vCenterCred -Force 

Write-Host "Running Get-DrsRule against $VC"
Log -Message "Running Get-DrsRule against $VC" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

    $DRSRules = Get-Cluster | Get-DrsRule | select Name,Cluster,Enabled,Type,@{N='VMs';E={((Get-VM -ID $_.VMIDs).Name)}}

        ForEach ($rule in $DRSRules){

                $DRSVMRuleReport += New-Object PSObject -Property @{

                    Name = [String]$rule.Name
                    Cluster = [String]$rule.Cluster
                    Enabled = [String]$rule.Enabled
                    Type = [String]$rule.Type
                    VMs = [String]($rule.VMs) | Sort-Object
                    Count = ($rule.VMs).Count
                    VC = [String]$VC
                }
        }


Write-Host "Running Get-DrsClusterGroup against $VC"
Log -Message "Running Get-DrsClusterGroup against $VC" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

    $DRSClusterGroup = Get-Cluster | Get-DrsClusterGroup | select Name,Cluster,Grouptype,@{N='Member';E={($_.Member)}}

        ForEach ($DRSGroup in $DRSClusterGroup){

                $DRSClusterGroupReport += New-Object PSObject -Property @{

                    Name = [String]$DRSGroup.Name
                    Cluster = [String]$DRSGroup.Cluster
                    Grouptype = [String]$DRSGroup.Grouptype
                    Member = [String]($DRSGroup.Member) | Sort-Object
                    Count = ($DRSGroup.Member).Count
                    VC = [String]$VC
                }
        }

    #CreatingHashLookupTable

    $DRSClusterGroupReport | ForEach-Object -Begin {
        $GroupLookup = @{}
    } -Process {
        $GroupLookup.add($_.Cluster + $_.Name +$_.Grouptype,$_.Member+'$'+$_.Count)
    }


Write-Host "Running Get-DrsVMHostRule against $VC"
Log -Message "Running Get-DrsVMHostRule against $VC" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

    $DRSVMHostRule = Get-Cluster | Get-DrsVMHostRule | select Name,Cluster,VMGroup,Type,VMHostGroup,Enabled

        ForEach ($HostRule in $DRSVMHostRule){

                $VMLookup = $HostRule.Cluster.name+$HostRule.VMGroup.Name+'VMGroup'
                $HostLookup = $HostRule.Cluster.name+$HostRule.VMHostGroup.Name+'VMHostGroup'

                $DRSVM2HOSTRuleReport += New-Object PSObject -Property @{

                    Name = [String]$HostRule.Name
                    Cluster = [String]$HostRule.Cluster
                    VMGroup = [String]$HostRule.VMGroup
                    VMGroupMembers = [String]($GroupLookup.Item($VMLookup)).Split('$')[0]
                    VMGroupMembersCount = [String]($GroupLookup.Item($VMLookup)).Split('$')[1]
                    Type = [String]$HostRule.Type
                    VMHostGroup = [String]$HostRule.VMHostGroup
                    VMHostGroupMembers = [String]($GroupLookup.Item($HostLookup)).Split('$')[0]
                    VMHostGroupMembersCount = [String]($GroupLookup.Item($HostLookup)).Split('$')[1]
                    Enabled = [String]$HostRule.Enabled
                    VC = [String]$VC
                }
            }


Write-Host "Disconnecting from $VC"
Log -Message "Disconnecting from $VC" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc
Disconnect-VIServer -Server $VC -Force -Confirm:$false

}

    ##GROUP STUFF##

            $DRSVMRuleReport = $DRSVMRuleReport | Group-Object Cluster
            $DRSClusterGroupReport = $DRSClusterGroupReport | Group-Object Cluster
            $DRSVM2HOSTRuleReport = $DRSVM2HOSTRuleReport | Group-Object Cluster

switch($ImportType)
    {

    Full {

########################
## Pushing Properties ##
########################

            Write-Host "Create XML's, lookup resourceId and pushing Custom DRS Properties to vRops for Clusters"
			Log -Message "Create XML's, lookup resourceId and pushing Custom DRS Properties to vRops for Clusters" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            ########################
            ##DRS VM RULES Section##
            ########################

            $XMLDRSRuleFile = @()

            #Create XML for DRS Rules, lookup resourceId and push Data to vRops

            ForEach($ClusterRules in $DRSVMRuleReport){

            #Create XML Structure and populate variables from the Metadata file for DRS Rules

                $XMLDRSRuleFile = @('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                            <ops:property-contents xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">')

                            ForEach($DRSRule in $ClusterRules.group){

                                $XMLDRSRuleFile += @('<ops:property-content statKey="VMAN|DRS|RULES|VM|{1}|TYPE">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{2}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM|{1}|VMs">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{3}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM|{1}|ENABLED">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{4}]]></ops:values>
        </ops:property-content>') -f $NowDateEpoc,
                            $DRSRule.'Name',
                            $DRSRule.'Type',
                            [String]$DRSRule.'VMs',
                            $DRSRule.'Enabled'
            }


                $XMLDRSRuleFile += @('</ops:property-contents>')

            [xml]$xmlSend = $XMLDRSRuleFile

            #ExportConfig
                        
            $ClusterRulesName = $ClusterRules.'Name'

            #Debug
            ##$output = $ScriptPath + '\' + $RunDateTime + '\' + $ClusterRulesName + '_RULES.xml'
            ##[xml]$xmlSend.Save($output)

            #Run the function to get the resourceId from the VM Name
            $resourceIDLookup = (GetObject $ClusterRulesName 'ClusterComputeResource' $vRopsAddress $vRopsAdminToken).Resourceid

            #Create URL string for Invoke-RestMethod
            $urlsend = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+ $resourceIDLookup + '/properties'

            Write-Host "Pushing DRS Rule Properties to $ClusterRulesName to $urlsend"
			Log -Message "Pushing DRS Rule Properties to $ClusterRulesName to $urlsend" -LogType "JOB-$RunDateTime" -LogFile $LogFileLo

            #Send Attribute data to vRops.
            $ContentType = "application/xml;charset=utf-8"
            Invoke-RestMethod -Method POST -uri $urlsend -Body $xmlSend -ContentType $ContentType -Headers $vRopsAdminToken

            #CleanUp Variables to make sure we dont update the next object with the same data as the previous one.
            Remove-Variable urlsend -ErrorAction SilentlyContinue
            Remove-Variable xmlSend -ErrorAction SilentlyContinue
            Remove-Variable XMLDRSRuleFile -ErrorAction SilentlyContinue
            Remove-Variable ClusterRules -ErrorAction SilentlyContinue
            Remove-Variable ClusterRulesName -ErrorAction SilentlyContinue
            }

            ########################
            ###DRS GROUPS Section###
            ########################

            $XMLDRSGroupFile = @()

            #Create XML for DRS Groups, lookup resourceId and push Data to vRops

            ForEach($ClusterGroup in $DRSClusterGroupReport){ 

            #Create XML Structure and populate variables from the Metadata file for DRS Groups

                $XMLDRSGroupFile = @('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                            <ops:property-contents xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">')

                            ForEach($DRSGroup in $ClusterGroup.group){

                                $XMLDRSGroupFile += @('<ops:property-content statKey="VMAN|DRS|GROUPS|{2}|{1}|MEMBERS">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{3}]]></ops:values>
        </ops:property-content>') -f $NowDateEpoc,
                            $DRSGroup.'Name',
                            $DRSGroup.'Grouptype',
                            [String]$DRSGroup.'Member'
            }


                $XMLDRSGroupFile += @('</ops:property-contents>')

            [xml]$xmlSend = $XMLDRSGroupFile

            #ExportConfig
                        
            $ClusterGroupName = $ClusterGroup.'Name'

            #Debug
            ##$output = $ScriptPath + '\' + $RunDateTime + '\' + $ClusterGroupName + '_GROUPS.xml'
            ##[xml]$xmlSend.Save($output)

            #Run the function to get the resourceId from the VM Name
            $resourceIDLookup = (GetObject $ClusterGroupName 'ClusterComputeResource' $vRopsAddress $vRopsAdminToken).Resourceid

            #Create URL string for Invoke-RestMethod
            $urlsend = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+ $resourceIDLookup + '/properties'

            Write-Host "Pushing DRS Group Properties to $ClusterGroupName to $urlsend"
			Log -Message "Pushing DRS Group Properties to $ClusterGroupName to $urlsend" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            #Send Attribute data to vRops.
            $ContentType = "application/xml;charset=utf-8"
            Invoke-RestMethod -Method POST -uri $urlsend -Body $xmlSend -ContentType $ContentType -Headers $vRopsAdminToken

            #CleanUp Variables to make sure we dont update the next object with the same data as the previous one.
            Remove-Variable urlsend -ErrorAction SilentlyContinue
            Remove-Variable xmlSend -ErrorAction SilentlyContinue
            Remove-Variable XMLDRSGroupFile -ErrorAction SilentlyContinue
            Remove-Variable ClusterGroup -ErrorAction SilentlyContinue
            Remove-Variable ClusterGroupName -ErrorAction SilentlyContinue
            }

            ########################
            ##DRS VM 2 HOST RULES ##
            ########################

            $XMLDRSRuleFile = @()

            #Create XML for DRS Rules, lookup resourceId and push Data to vRops

            ForEach($ClusterVM2HOSTRules in $DRSVM2HOSTRuleReport){ 

            #Create XML Structure and populate variables from the Metadata file for DRS Rules

                $XMLDRSVM2HOSTRuleFile  = @('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                            <ops:property-contents xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">')

                            ForEach($DRSVM2HOSTRule in $ClusterVM2HOSTRules.group){

                                $XMLDRSVM2HOSTRuleFile += @('<ops:property-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|TYPE">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{2}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|HOSTGROUP">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{3}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|HOSTGROUPMEMBERS">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{4}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|VMGROUP">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{5}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|VMGROUPMEMBERS">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{6}]]></ops:values>
        </ops:property-content>
        <ops:property-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|ENABLED">
            <ops:timestamps>{0}</ops:timestamps>
            <ops:values><![CDATA[{7}]]></ops:values>
        </ops:property-content>') -f $NowDateEpoc,
                            $DRSVM2HOSTRule.'Name',
                            $DRSVM2HOSTRule.'Type',
                            $DRSVM2HOSTRule.'VMHostGroup',
                            $DRSVM2HOSTRule.'VMHostGroupMembers',
                            $DRSVM2HOSTRule.'VMGroup',
                            $DRSVM2HOSTRule.'VMGroupMembers',
                            $DRSVM2HOSTRule.'Enabled'
            }


                $XMLDRSVM2HOSTRuleFile += @('</ops:property-contents>')

            [xml]$xmlSend = $XMLDRSVM2HOSTRuleFile 

            #ExportConfig
                        
            $ClusterVM2HOSTRulesName = $ClusterVM2HOSTRules.Name 

            #Debug
            ##$output = $ScriptPath + '\' + $RunDateTime + '\' + $ClusterVM2HOSTRulesName + '_DRSVM2HOSTRULES.xml'
            ##[xml]$xmlSend.Save($output)

            #Run the function to get the resourceId from the VM Name
            $resourceIDLookup = (GetObject $ClusterVM2HOSTRulesName 'ClusterComputeResource' $vRopsAddress $vRopsAdminToken).Resourceid

            #Create URL string for Invoke-RestMethod
            $urlsend = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+ $resourceIDLookup + '/properties'

            Write-Host "Pushing DRS VM2HOST Rule Properties to $ClusterVM2HOSTRulesName to $urlsend"
			Log -Message "Pushing DRS VM2HOST Properties to $ClusterVM2HOSTRulesName to $urlsend" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            #Send Attribute data to vRops.
            $ContentType = "application/xml;charset=utf-8"
            Invoke-RestMethod -Method POST -uri $urlsend -Body $xmlSend -ContentType $ContentType -Headers $vRopsAdminToken

            #CleanUp Variables to make sure we dont update the next object with the same data as the previous one.
            Remove-Variable urlsend -ErrorAction SilentlyContinue
            Remove-Variable xmlSend -ErrorAction SilentlyContinue
            Remove-Variable XMLDRSRuleFile -ErrorAction SilentlyContinue
            Remove-Variable ClusterVM2HOSTRules -ErrorAction SilentlyContinue
            Remove-Variable ClusterVM2HOSTRulesName -ErrorAction SilentlyContinue
            }



########################
### Pushing Metrics ####
########################

#Push in DRSVMRule Metrics

If ($DRSVMRuleReport){

    $DRSVMRuleMetricXML = @()

    ForEach($DRSVMRuleMetric in $DRSVMRuleReport){ 


    $DRSVMRuleMetricXML = @('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <ops:stat-contents xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">')

            ForEach ($DRSVMRuleMetricInsert in $DRSVMRuleMetric.group){

                $DRSVMRuleMetricXML += @('<ops:stat-content statKey="VMAN|DRS|RULES|VM|{1}|VMRULEMEMBERSCOUNT">
    <ops:timestamps>{0}</ops:timestamps>
    <ops:data>{2}</ops:data>
    <ops:unit>%</ops:unit>
</ops:stat-content>' -f $NowDateEpoc,
                        $DRSVMRuleMetricInsert.'Name',
                        $DRSVMRuleMetricInsert.'Count')
                }


        $DRSVMRuleMetricXML += @('</ops:stat-contents>')

        [xml]$DRSVMRuleMetricXML = $DRSVMRuleMetricXML

        $DRSVMRuleMetricName = $DRSVMRuleMetric.Name

        $vRopsMetricURL = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+$resourceIDLookup+'/stats'

        Write-Host "Pushing DRSVMRule Metrics for cluster $DRSVMRuleMetricName to $vRopsMetricURL"
		Log -Message "Pushing DRSVMRule Metrics for cluster $DRSVMRuleMetricName to $vRopsMetricURL" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

        Invoke-RestMethod -Method POST -uri $vRopsMetricURL -Body $DRSVMRuleMetricXML -ContentType "application/xml;charset=utf-8" -Headers $vRopsAdminToken

        Remove-Variable vRopsMetricURL -ErrorAction SilentlyContinue
        Remove-Variable DRSVMRuleMetricXML -ErrorAction SilentlyContinue
        Remove-Variable MetricInsert -ErrorAction SilentlyContinue
    }

}

#Push in DRSClusterGroup Metrics

If ($DRSClusterGroupReport){

    $DRSClusterGroupMetricXML = @()

    ForEach($DRSClusterGroupMetric in $DRSClusterGroupReport){ 

    $DRSClusterGroupMetricXML = @('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <ops:stat-contents xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">')

            ForEach ($DRSClusterGroupMetricInsert in $DRSClusterGroupMetric.group){

                $DRSClusterGroupMetricXML += @('<ops:stat-content statKey="VMAN|DRS|GROUPS|{2}|{1}|">
        <ops:timestamps>{0}</ops:timestamps>
        <ops:data>{3}</ops:data>
        <ops:unit>%</ops:unit>
        </ops:stat-content>' -f $NowDateEpoc,
                            $DRSClusterGroupMetricInsert.'Name',
                            $DRSClusterGroupMetricInsert.'Grouptype',
                            $DRSClusterGroupMetricInsert.'Count')
                }


        $DRSClusterGroupMetricXML += @('</ops:stat-contents>')

        [xml]$DRSClusterGroupMetricXML = $DRSClusterGroupMetricXML

        $DRSClusterGroupMetricName = $DRSClusterGroupMetric.Name

        $vRopsMetricURL = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+$resourceIDLookup+'/stats'

        Write-Host "Pushing DRSClusterGroup Metrics for cluster $DRSClusterGroupMetricName to $vRopsMetricURL"
		Log -Message "Pushing DRSClusterGroup Metrics for cluster $DRSClusterGroupMetricName to $vRopsMetricURL" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

        Invoke-RestMethod -Method POST -uri $vRopsMetricURL -Body $DRSClusterGroupMetricXML -ContentType "application/xml;charset=utf-8" -Headers $vRopsAdminToken

        Remove-Variable vRopsMetricURL -ErrorAction SilentlyContinue
        Remove-Variable DRSClusterGroupMetricXML -ErrorAction SilentlyContinue
        Remove-Variable MetricInsert -ErrorAction SilentlyContinue
    }

}
#Push in DRSVM2HOSTRule Metrics

if ($DRSClusterGroupReport){

    $DRSVM2HOSTRuleMetricXML = @()

    ForEach($DRSVM2HOSTRuleMetric in $DRSClusterGroupReport){ 

    $DRSVM2HOSTRuleMetricXML = @('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                        <ops:stat-contents xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">')

            ForEach ($DRSVM2HOSTRuleMetricInsert in $DRSVM2HOSTRuleReport.group){

                $DRSVM2HOSTRuleMetricXML += @('<ops:stat-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|VMGROUPMEMBERSCOUNT">
    <ops:timestamps>{0}</ops:timestamps>
    <ops:data>{2}</ops:data>
    <ops:unit>%</ops:unit>
    </ops:stat-content>
    <ops:stat-content statKey="VMAN|DRS|RULES|VM2HOST|{1}|HOSTGROUPMEMBERSCOUNT">
    <ops:timestamps>{0}</ops:timestamps>
        <ops:data>{3}</ops:data>
        <ops:unit>%</ops:unit>
    </ops:stat-content>' -f $NowDateEpoc,
                        $DRSVM2HOSTRuleMetricInsert.'Name',
                        $DRSVM2HOSTRuleMetricInsert.'VMHostGroupMembersCount',
                        $DRSVM2HOSTRuleMetricInsert.'VMGroupMembersCount')
                    }
                    
        $DRSVM2HOSTRuleMetricXML += @('</ops:stat-contents>')

        $DRSVM2HOSTRuleMetricName = $DRSVM2HOSTRuleMetric.Name

        $vRopsMetricURL = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+$resourceIDLookup+'/stats'

        Write-Host "Pushing DRSVM2HOSTRule Metrics for cluster $DRSVM2HOSTRuleMetricName to $vRopsMetricURL"
		Log -Message "Pushing DRSVM2HOSTRule Metrics for cluster $DRSVM2HOSTRuleMetricName to $vRopsMetricURL" -LogType "JOB-$RunDateTime" -LogFile $LogFileLo

        Invoke-RestMethod -Method POST -uri $vRopsMetricURL -Body $DRSVM2HOSTRuleMetricXML -ContentType "application/xml;charset=utf-8" -Headers $vRopsAdminToken

        Remove-Variable vRopsMetricURL -ErrorAction SilentlyContinue
        Remove-Variable DRSVM2HOSTRuleMetricXML -ErrorAction SilentlyContinue
        Remove-Variable MetricInsert -ErrorAction SilentlyContinue
        }
}
Write-Host "Done Importing Custom DRS properties Clusters into vROPS"
Log -Message "Done Importing Custom DRS properties Clusters into vROPS" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            }
    Diff {

            #Coming Soon
        }

}

Write-Host "Script Finished"
Log -Message "Script Finished" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc
