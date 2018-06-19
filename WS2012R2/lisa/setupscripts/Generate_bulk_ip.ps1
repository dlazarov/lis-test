#####################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#####################################################################

<#
.Synopsis
 Description:
    This script generates the static IPs necessary for some remote tests.
    The following testParams are mandatory:
        sshKey=sshKey.ppk
            The private key which will be used to allow sending information to the VM.
    All test scripts must return a boolean ($true or $false)
    to indicate if the script completed successfully or not.
    .Parameter vmName
    Name of the first VM implicated in the test .
    .Parameter hvServer
    Name of the Hyper-V server hosting the VM.
    .Parameter testParams
    Test data for this test case
    .Example
        InjectIPconstants.ps1 -vmName myVM -hvServer localhost -testParams "AddressFamily=IPv6"

#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

# sshKey used to athenticate ssh connection and send commands
$sshKey = $null

# Ip Address of first VM
$ipv4 = $null

# Parameter for IP Generation
$ipStaticParam = $null

#List of commands to be sent to VM
$cmd = $null

#
# Helper function to execute command of remote machine
#
function Execute ([string] $command)
{
    .\bin\plink.exe -i ssh\${sshKey} root@${ipv4} $command
    return $?
}

#
# Check input arguments
#

if ($vmName -eq $null)
{
    "Error: VM name is null"
    return $false
}

if ($hvServer -eq $null)
{
    "Error: hvServer is null"
    return $false
}

if ($testParams -eq $null)
{
    "Error: testParams is null"
}

# Write out test parameters
$testParams

# Change working directory to root directory
$testParams -match "RootDir=([^;]+)"
if (-not $?)
{
    "Mandatory param RootDir=Path; not found"
    return $false
}

$rootDir = $Matches[1]

if (Test-Path $rootDir)
{
    Set-Location -Path $rootDir
    if (-not $?)
    {
        "Error; Could not change directory to $rootDir"
        return $false
    }
}
else
{
    "Error: RootDir = $rootDir is not a valid path"
}

# Source TCUtils.ps1
if (Test-Path ".\setupScripts\TCUtils.ps1")
{
    . .\setupScripts\TCUtils.ps1
}
else
{
    "Error: Could not find setupScripts\TCUtils.ps1"
    return $false
}


$params = $testParams.Split(";")
foreach ($p in $params)
{
    $fields = $p.Split("=")

    switch ($fields[0].Trim())
    {
        "sshKey"    { $sshKey = $fields[1].Trim() }
        "ipv4"      { $ipv4 = $fields[1].Trim() }
        "IP_STATIC" { $ipStaticParam = $fields[1].Trim() }
        default     {} # Ignore unknown parameter
    }
}

if (-not $sshKey)
{
    "Error: test parameter sshKey was not specified"
    return $false
}

$ipv4 = GetIPv4 $vmName $hvServer

if (-not $ipv4) {
    "Error: could not retrieve test VM's test IP address"
    return $false
}

# Checking global variable for static IP generation in StartVM.ps1
if($globalStaticIp)
{
    $bulk = ($IpArray.Length - 1)
    # command to add netmask to constants file
    $cmd += "echo `"NETMASK=$($IpArray[0])`" >> ~/constants.sh;"
    $i = 1

    while ($i -le $bulk)
    {
        #command to add static IP to constants file
        $cmd += "echo `"STATIC_IP$($i)=$($IpArray[$i])`" >> ~/constants.sh;"
        $i++
    }
}
else
{

    if (-not $ipStaticParam)
    {
        "Error: IP_STATIC parameter was not specified"
        return $false
    }

    # Split ipStaticParam to get individual arguments for GenerateBulkIp function
    $paramValue = $ipStaticParam.Trim().Split('=')
    $staticIpArgs = $paramValue.Split(',')

    $IpArray = @()
    $bulk = $staticIpArgs[1].Trim()

    if ($staticIpArgs[0].Trim() -eq "ipv4" -and $staticIpArgs.Length -in 3..4)
    {
        $class = $staticIpArgs[2].Trim()
        $netmaskParam = $staticIpArgs[3]
        $IpArray = GenerateBulkIp -ipv4 -bulk $bulk -class $class -netmaskIpv4 $netmaskParam
    }
    elseif ($staticIpArgs[0].Trim() -eq "ipv6" -and $staticIpArgs.Length -in 2..3)
    {
        $netmaskParam = $staticIpArgs[2]
        $IpArray = GenerateBulkIp -ipv6 -bulk $bulk -netmaskIpv6 $netmaskParam
    }
    else
    {
        "Error: Incorrect arguments for IP_STATIC: $($paramValue[1])"
        return $false
    }

    if (-not $IpArray)
    {
        "Error: Failed to generate static IPs"
        return $false
    }
    else
    {
        # command to add netmask to constants file
        $cmd += "echo `"NETMASK=$($IpArray[0])`" >> ~/constants.sh;"
        $i = 1

        while ($i -le $bulk)
        {
            #command to add static IP to constants file
            $cmd += "echo `"STATIC_IP$($i)=$($IpArray[$i])`" >> ~/constants.sh;"
            $i++
        }
    }
}

$result = Execute($cmd)

if (-not $result)
{
    "Error: Unable to submit ${cmd} to vm"
    # return $false
}

"Static IP succesfully added to constants file"

return $true