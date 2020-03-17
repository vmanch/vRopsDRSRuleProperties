#Powershell collector script for DRS rules and pushing the results into vROPS.
#v1.0 vMan.ch, 15.11.2019 - Initial Version

<#
    Run the command below to store user and pass in secure credential XML for each environment

        $cred = Get-Credential
        $cred | Export-Clixml -Path "vROPS.xml"
#>

param
(
  [Array]$vCenter,
  [String]$creds,
	[String]$vRopsAddress,
	[String]$vRopsCreds,
	[String]$ImportType = 'Full'
)

#Logging Function
Function Log([String]$message, [String]$LogType, [String]$LogFile){
    $date = Get-Date -UFormat '%m-%d-%Y %H:%M:%S'
    $message = $date + "`t" + $LogType + "`t" + $message
    $message >> $LogFile
}


#Log rotation function
function Reset-Log 
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

Function GetReport([String]$vRopsAddress, [String]$ReportResourceID, [String]$ReportID, $vRopsCreds, $Path){
 
Write-host 'Running Report'
 
#RUN Report
 
$ContentType = "application/xml;charset=utf-8"
$header = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$header.Add("Accept", 'application/xml')
 
$RunReporturl = 'https://'+$vRopsAddress+'/suite-api/api/reports'
 
$Body = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ops:report xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:ops="http://webservice.vmware.com/vRealizeOpsMgr/1.0/">
    <ops:resourceId>$ReportResourceID</ops:resourceId>
    <ops:reportDefinitionId>$ReportID</ops:reportDefinitionId>
</ops:report>
"@
 
 
[xml]$Data = Invoke-RestMethod -Method POST -uri $RunReporturl -Credential $vRopsCreds -ContentType $ContentType -Headers $header -Body $body
 
$ReportLink = $Data.report.links.link | Where name -eq 'linkToSelf' | Select 'href'	
 
$ReportLinkurl = 'https://' + $vRopsAddress + $ReportLink.href
 
#Check if report is run to download
 
[xml]$ReportStatus = Invoke-RestMethod -Method GET -uri $ReportLinkurl -Credential $vRopsCreds -ContentType $ContentType -Headers $header
 
 
While ($ReportStatus.report.status -ne "COMPLETED") {
    [xml]$ReportStatus = Invoke-RestMethod -Method GET -uri $ReportLinkurl -Credential $vRopsCreds -ContentType $ContentType -Headers $header
    Write-host 'Waiting for report to finish running, current status: '  $ReportStatus.report.status
    Sleep 3
      } # End of block statement
 
 
$ReportDownload = $ReportLinkurl + '/download?format=CSV'
 
Invoke-RestMethod -Method GET -uri $ReportDownload -Credential $vRopsCreds -ContentType $ContentType -Headers $header -OutFile $Path
 
 
return $Path
}

#Lookup Function to get resourceId from VM Name
Function GetObject([String]$vRopsObjName, [String]$resourceKindKey, [String]$vRopsServer, $vRopsCredentials){

    $vRopsObjName = $vRopsObjName -replace ' ','%20'

    [xml]$Checker = Invoke-RestMethod -Method Get -Uri "https://$vRopsServer/suite-api/api/resources?resourceKind=$resourceKindKey&name=$vRopsObjName" -Credential $vRopsCredentials -Headers $header -ContentType $ContentType

#Check if we get 0

    if ([Int]$Checker.resources.pageInfo.totalCount -eq '0'){

    Return $CheckerOutput = ''

    }

    else {

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

                            $CheckerOutput = New-Object PsObject -Property @{Name=$vRopsObjName; resourceId=$Result.identifier; resourceKindKey=$Result.resourceKey.resourceKindKey}

                            Return $CheckerOutput
                    
                        }   
                    }
            }  
         }

        else {
    
            $CheckerOutput = New-Object PsObject -Property @{Name=$vRopsObjName; resourceId=$Checker.resources.resource.identifier; resourceKindKey=$Checker.resources.resource.resourceKey.resourceKindKey}

            Return $CheckerOutput

            }
        }
}

$ScriptPath = (Get-Item -Path ".\" -Verbose).FullName
$random = get-random
$RunDateTime = (Get-date)
$RunDateTime = $RunDateTime.tostring("yyyyMMddHHmmss")
$RunDateTime = $RunDateTime + '_'  + $random
$LogFileLoc = $ScriptPath + '\Log\Logfile.log'
[DateTime]$NowDate = (Get-date)
[int64]$NowDateEpoc = (([DateTimeOffset](Get-Date)).ToUniversalTime().ToUnixTimeMilliseconds())

#cleanupLogFile
$LogFileLoc = $ScriptPath + '\Log\Logfile.log'
Reset-Log -fileName $LogFileLoc -filesize 10mb -logcount 5


if($creds -gt ""){

    $cred = Import-Clixml -Path "$ScriptPath\config\$creds.xml"

    }
    else
    {
    echo "Environment not selected, stop hammer time!"
    Exit
    }

if($vRopsCreds -gt ""){

    $vRopsCred = Import-Clixml -Path "$ScriptPath\config\$vRopsCreds.xml"

    }
    else
    {
    echo "Environment not selected, stop hammer time!"
    Exit
    }

Log -Message "Starting Script" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

$DRSVMRuleReport = @()
$DRSClusterGroupReport = @()
$DRSVM2HOSTRuleReport = @()

ForEach ($VC in $vCenter){


Log -Message "Connecting to $VC with credentials $creds" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

Connect-VIServer -server $VC -Credential $cred -Force 


    $DRSRules = Get-Cluster | Get-DrsRule | select Name,Cluster,Enabled,Type,@{N='VMs';E={((Get-VM -ID $_.VMIDs).Name)}}

        ForEach ($rule in $DRSRules){

                $DRSVMRuleReport += New-Object PSObject -Property @{

                    Name = $rule.Name
                    Cluster = $rule.Cluster
                    Enabled = $rule.Enabled
                    Type = $rule.Type
                    VMs = ($rule.VMs) | Sort-Object
                    VC = [String]$VC
                }
        }




    $DRSClusterGroup = Get-Cluster | Get-DrsClusterGroup | select Name,Cluster,Grouptype,@{N='Member';E={($_.Member)}}

        ForEach ($DRSGroup in $DRSClusterGroup){

                $DRSClusterGroupReport += New-Object PSObject -Property @{

                    Name = [String]$DRSGroup.Name
                    Cluster = [String]$DRSGroup.Cluster
                    Grouptype = [String]$DRSGroup.Grouptype
                    Member = [String]($DRSGroup.Member) | Sort-Object
                    VC = [String]$VC
                }
        }

    #CreatingHashLookupTable

    $DRSClusterGroupReport | ForEach-Object -Begin {
        $GroupLookup = @{}
    } -Process {
         $GroupLookup.add($_.Cluster + $_.Name +$_.Grouptype,$_.Member)
    }


    $DRSVMHostRule = Get-Cluster | Get-DrsVMHostRule | select Name,Cluster,VMGroup,Type,VMHostGroup,Enabled

        ForEach ($HostRule in $DRSVMHostRule){

                $VMLookup = $HostRule.Cluster.name+$HostRule.VMGroup.Name+'VMGroup'
                $HostLookup = $HostRule.Cluster.name+$HostRule.VMHostGroup.Name+'VMHostGroup'

                $DRSVM2HOSTRuleReport += New-Object PSObject -Property @{

                    Name = $HostRule.Name
                    Cluster = $HostRule.Cluster
                    VMGroup = $HostRule.VMGroup
                    VMGroupMembers = $GroupLookup.Item($VMLookup)
                    Type = $HostRule.Type
                    VMHostGroup = $HostRule.VMHostGroup
                    VMHostGroupMembers = $GroupLookup.Item($HostLookup)
                    Enabled = $HostRule.Enabled
                    VC = [String]$VC
                }
            }

    ##GROUP STUFF##

            $DRSVMRuleReport = $DRSVMRuleReport | Group-Object Cluster
            $DRSClusterGroupReport = $DRSClusterGroupReport | Group-Object Cluster
            $DRSVM2HOSTRuleReport = $DRSVM2HOSTRuleReport | Group-Object Cluster

Disconnect-VIServer -Server $VC -Force -Confirm:$false

}

switch($ImportType)
    {

    Full {

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

            ##Debug Baby
            
            $ClusterRulesName = $ClusterRules.'Name'

            ##$output = $ScriptPath + '\XML\' + $ClusterRulesName' + '_RULES.xml'

            ##[xml]$xmlSend.Save($output)

            #Run the function to get the resourceId from the VM Name
            $resourceLookup = GetObject $ClusterRulesName 'ClusterComputeResource' $vRopsAddress $vRopsCred

            #Create URL string for Invoke-RestMethod
            $urlsend = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+ $resourceLookup.resourceId + '/properties'

            Write-Host "Pushing DRS Rule Properties to $ClusterRulesName to $urlsend"
            Log -Message "Pushing DRS Rule Properties to $ClusterRulesName to $urlsend" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            #Send Attribute data to vRops.
            $ContentType = "application/xml;charset=utf-8"
            Invoke-RestMethod -Method POST -uri $urlsend -Body $xmlSend -Credential $vRopsCred -ContentType $ContentType

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

            ##Debug Baby
            
            $ClusterGroupName = $ClusterGroup.'Name'

            #$output = $ScriptPath + '\XML\' + $ClusterGroupName + '_GROUPS.xml'

            #[xml]$xmlSend.Save($output)

            #Run the function to get the resourceId from the VM Name
            $resourceLookup = GetObject $ClusterGroupName 'ClusterComputeResource' $vRopsAddress $vRopsCred

            #Create URL string for Invoke-RestMethod
            $urlsend = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+ $resourceLookup.resourceId + '/properties'

            Write-Host "Pushing DRS Group Properties to $ClusterGroupName to $urlsend"
            Log -Message "Pushing DRS Group Properties to $ClusterGroupName to $urlsend" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            #Send Attribute data to vRops.
            $ContentType = "application/xml;charset=utf-8"
            Invoke-RestMethod -Method POST -uri $urlsend -Body $xmlSend -Credential $vRopsCred -ContentType $ContentType

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

            ##Debug Baby
            
            $ClusterVM2HOSTRulesName = $ClusterVM2HOSTRules.Name 

            ##$output = $ScriptPath + '\XML\' + $ClusterVM2HOSTRulesName + '_DRSVM2HOSTRULES.xml'

            ##[xml]$xmlSend.Save($output)

            #Run the function to get the resourceId from the VM Name
            $resourceLookup = GetObject $ClusterVM2HOSTRulesName 'ClusterComputeResource' $vRopsAddress $vRopsCred

            #Create URL string for Invoke-RestMethod
            $urlsend = 'https://' + $vRopsAddress + '/suite-api/api/resources/'+ $resourceLookup.resourceId + '/properties'

            Write-Host "Pushing DRS VM2HOST Rule Properties to $ClusterVM2HOSTRulesName to $urlsend"
            Log -Message "Pushing DRS VM2HOST Properties to $ClusterVM2HOSTRulesName to $urlsend" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            #Send Attribute data to vRops.
            $ContentType = "application/xml;charset=utf-8"
            Invoke-RestMethod -Method POST -uri $urlsend -Body $xmlSend -Credential $vRopsCred -ContentType $ContentType

            #CleanUp Variables to make sure we dont update the next object with the same data as the previous one.
            Remove-Variable urlsend -ErrorAction SilentlyContinue
            Remove-Variable xmlSend -ErrorAction SilentlyContinue
            Remove-Variable XMLDRSRuleFile -ErrorAction SilentlyContinue
            Remove-Variable ClusterVM2HOSTRules -ErrorAction SilentlyContinue
            Remove-Variable ClusterVM2HOSTRulesName -ErrorAction SilentlyContinue
            }

            Write-Host "Done Importing Custom DRS properties Clusters into vROPS"
            Log -Message "Done Importing Custom DRS properties Clusters into vROPS" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc

            }
    Diff {

            #Coming Soon
        }

}

Log -Message "Script Finished" -LogType "JOB-$RunDateTime" -LogFile $LogFileLoc