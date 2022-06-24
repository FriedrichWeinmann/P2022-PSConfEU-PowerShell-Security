$labname = 'PSSecurity'
$domainName = 'contoso.com'
$imageUI = 'Windows Server 2019 Datacenter (Desktop Experience)'
$demoBaseFolder = Split-Path $PSScriptRoot

$modules = @(
	'PSFramework'
	'PSUtil'
	'PSModuleDevelopment'
	'Revoke-Obfuscation'
	'ScriptBlockLoggingAnalyzer'
)

#region Default Lab Setup
New-LabDefinition -Name $labname -DefaultVirtualizationEngine HyperV

$parameters = @{
	Memory		    = 2GB
	OperatingSystem = $imageUI
	DomainName	    = $domainName
}

Add-LabMachineDefinition -Name PSSecDC -Roles RootDC @parameters
Add-LabMachineDefinition -Name PSSecAdminHost @parameters
Add-LabMachineDefinition -Name PSSecRDP @parameters
Add-LabMachineDefinition -Name PSSecDesktop1 @parameters
Add-LabMachineDefinition -Name PSSecDesktop2 @parameters

Install-Lab

Install-LabWindowsFeature -ComputerName PSSecAdminHost -FeatureName NET-Framework-Core, NET-Non-HTTP-Activ, GPMC, RSAT-AD-Tools

$allVMs = Get-LabVM

Invoke-LabCommand -ActivityName "Setting Keyboard Layout" -ComputerName $allVMs -ScriptBlock {
	Set-WinUserLanguageList -LanguageList 'de-de' -Confirm:$false -Force
	$null = New-Item -Path "C:\" -Name "Scripts" -ItemType Directory -Force
}
#endregion Default Lab Setup

#region PowerShell Resources
# Deploy Modules
$tempFolder = New-Item -Path $env:temp -Name "PSSec-$(Get-Random -Minimum 1000 -Maximum 9999)" -ItemType Directory -Force
foreach ($module in $modules) { Save-Module $module -Path $tempFolder.FullName -Repository PSGallery }
foreach ($item in (Get-ChildItem -Path $tempFolder.FullName))
{
	Copy-LabFileItem -Path $item.FullName -DestinationFolderPath "C:\Program Files\WindowsPowerShell\Modules\" -ComputerName $allVMs
}
Remove-Item -Path $tempFolder.FullName -Recurse -Force

# Deploy demo material
foreach ($item in (Get-ChildItem -Path "$($demoBaseFolder)\DemoSources"))
{
	Copy-LabFileItem -Path $item.FullName -DestinationFolderPath 'C:\Scripts' -ComputerName PSSecAdminHost
}

# Deploy evil malware
$client = [System.Net.WebClient]::new()
$bytes = $client.DownloadData('https://github.com/danielbohannon/Invoke-Obfuscation/archive/master.zip')
$session = Get-LabPSSession -ComputerName PSSecAdminHost
Invoke-Command -Session $session -ScriptBlock {
	if (-not (Test-Path 'C:\temp')) { $null = New-Item C:\temp -ItemType Directory -Force}
	[System.IO.File]::WriteAllBytes('C:\temp\Invoke-Obfuscation.zip', $using:bytes)
	Expand-Archive 'C:\temp\Invoke-Obfuscation.zip' -DestinationPath 'C:\temp\'
	Move-Item -Path 'C:\temp\Invoke-Obfuscation-master' -Destination 'C:\Program Files\WindowsPowerShell\Modules\Invoke-Obfuscation'
}

#endregion PowerShell Resources

#region Lab: PowerShell Hardening
# Deploy AD Configuration
Invoke-LabCommand -ComputerName PSSecDC -ActivityName "Prepare OU Structure and move computer accounts" -ScriptBlock {
	$baseOU = New-ADOrganizationalUnit -Name Contoso -Path 'DC=contoso,DC=com' -PassThru
	$clients = New-ADOrganizationalUnit -Name Clients -Path $baseOU -PassThru
	$servers = New-ADOrganizationalUnit -Name Servers -Path $baseOU -PassThru
	$users = New-ADOrganizationalUnit -Name Users -Path $baseOU -PassThru
	New-ADOrganizationalUnit -Name Groups -Path $baseOU
	New-ADUser -Name Max.Mustermann -SamAccountName Max.Mustermann -UserPrincipalName Max.Mustermann@contoso.com -AccountPassword ("Test1234"|ConvertTo-SecureString -AsPlainText -Force) -Path $users -Enabled $true

	'PSSecDesktop1', 'PSSecDesktop2' | Get-ADComputer | Move-ADObject -TargetPath $clients
	'PSSecAdminHost', 'PSSecRDP' | Get-ADComputer | Move-ADObject -TargetPath $servers
}

Start-Sleep -Seconds 5

# Apply local group membership for test account
Invoke-LabCommand -ComputerName PSSecDesktop1, PSSecDesktop2 -ScriptBlock {
	Add-LocalGroupMember -Group (Get-LocalGroup -SID  S-1-5-32-555) -Member 'contoso\max.mustermann'
}
#endregion Lab: PowerShell Hardening

Write-Host "Waiting for 120 Seconds to allow processes to finish"
Start-Sleep -Seconds 120
Restart-LabVM -ComputerName $allVMs

Write-Host @"
Lab deployment complete!
  Administrator password: Somepass1
  Test User: Max.Mustermann
  Password:  Test1234
"@