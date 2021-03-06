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
 Run the Private network test.

 Description:
    Use two VMs to test a Private Network.

    The first VM is started by the LIS framework, while the second one will be managed by this script.

    The script expects a NIC param in the same format as the NET_{ADD|REMOVE|SWITCH}_NIC_MAC.ps1 scripts. It checks both VMs
    for a NIC connected to the specified network. If the first VM's NIC is not found, test will fail. In case the second VM is missing
    this NIC, it will call the NET_ADD_NIC_MAC.ps1 script directly and add it. If the NIC was added by this script, it will also clean-up
    after itself, unless the LEAVE_TRAIL param is set to `YES'.

    After both VMs are up, one VM will try to ping the other through the test interfaces which are set to be pivate.

    If the above ping succeeded, the test passed.

    The following testParams are mandatory:

        NIC=NIC type, Network Type, Network Name, MAC Address

            NIC Type can be one of the following:
                NetworkAdapter
                LegacyNetworkAdapter

            Network Type can be one of the following:
                Private

            Network Name is the name of a existing network.

            Only the Network Name parameter is used by this script, but the others are still necessary, in order to have the same
            parameters as the NET_ADD_NIC_MAC script.

            The following is an example of a testParam for removing a NIC

                "NIC=NetworkAdapter,Private,MyPrivateNetwork,001600112200"

        VM2NAME=name_of_second_VM
            this is the name of the second VM. It will not be managed by the LIS framework, but by this script.

    The following testParams are optional:

        STATIC_IP=xx.xx.xx.xx
            xx.xx.xx.xx is a valid IPv4 Address. If not specified, a default value of 10.10.10.1 will be used.
            This will be assigned to VM1's test NIC.

        STATIC_IP2=xx.xx.xx.xx
            xx.xx.xx.xx is a valid IPv4 Address. If not specified, an IP Address from the same subnet as VM1's STATIC_IP
            will be computed (usually the first address != STATIC_IP in the subnet). This will be assigned as VM2's test NIC.

        NETMASK=yy.yy.yy.yy
            yy.yy.yy.yy is a valid netmask (the subnet to which the tested netAdapters belong). If not specified, a default value of 255.255.255.0 will be used.

        LEAVE_TRAIL=yes/no
            if set to yes and the NET_ADD_NIC_MAC.ps1 script was called from within this script for VM2, then it will not be removed
            at the end of the script. Also temporary bash scripts generated during the test will not be deleted.

    All test scripts must return a boolean ($true or $false)
    to indicate if the script completed successfully or not.

   .Parameter vmName
    Name of the first VM implicated in the test .

    .Parameter hvServer
    Name of the Hyper-V server hosting the VM.

    .Parameter testParams
    Test data for this test case

    .Example
    NET_PRIVATE_NETWORK -vmName sles11sp3x64 -hvServer localhost -testParams "NIC=NetworkAdapter,Private,Private,001600112200;VM2NAME=second_sles11sp3x64"
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

Set-PSDebug -Strict

# function which creates an /etc/sysconfig/network-scripts/ifcfg-ethX file for interface ethX
function CreateInterfaceConfig([String]$conIpv4,[String]$sshKey,[String]$MacAddr,[String]$staticIP,[String]$netmask)
{

    # Add delimiter if needed
    if (-not $MacAddr.Contains(":"))
    {
        for ($i=2; $i -lt 16; $i=$i+2)
        {
            $MacAddr = $MacAddr.Insert($i,':')
            $i++
        }
    }

    # create command to be sent to VM. This determines the interface based on the MAC Address.

    $cmdToVM = @"
#!/bin/bash
        cd /root
        if [ -f utils.sh ]; then
            sed -i 's/\r//' utils.sh
            . utils.sh
        else
            exit 1
        fi

        # make sure we have synthetic network adapters present
        GetSynthNetInterfaces
        if [ 0 -ne `$? ]; then
            exit 2
        fi

        # get the interface with the given MAC address
        __sys_interface=`$(grep -il ${MacAddr} /sys/class/net/*/address)
        if [ 0 -ne `$? ]; then
            exit 3
        fi
        __sys_interface=`$(basename "`$(dirname "`$__sys_interface")")
        if [ -z "`$__sys_interface" ]; then
            exit 4
        fi

        echo CreateIfupConfigFile: interface `$__sys_interface >> /root/NET_PRIVATE_NETWORK.log 2>&1
        CreateIfupConfigFile `$__sys_interface static $staticIP $netmask >> /root/NET_PRIVATE_NETWORK.log 2>&1
        __retVal=`$?
        echo CreateIfupConfigFile: returned `$__retVal >> /root/NET_PRIVATE_NETWORK.log 2>&1
        exit `$__retVal
"@

    $filename = "CreateInterfaceConfig.sh"

    # check for file
    if (Test-Path ".\${filename}")
    {
        Remove-Item ".\${filename}"
    }

    Add-Content $filename "$cmdToVM"

    # send file
    $retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${$filename}"

    # delete file unless the Leave_trail param was set to yes.
    if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
    {
        Remove-Item ".\${filename}"
    }

    # check the return Value of SendFileToVM
    if (-not $retVal)
    {
        return $false
    }

    # execute sent file
    $retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

    return $retVal
}


function pingVMs([String]$conIpv4,[String]$pingTargetIpv4,[String]$sshKey,[int]$noPackets,[String]$macAddr)
{
    # check the number of Packets to be sent to the VM
    if ($noPackets -lt 0)
    {
        return $false
    }

    # Add delimiter if needed
    if (-not $MacAddr.Contains(":"))
    {
        for ($i=2; $i -lt 16; $i=$i+2)
        {
            $MacAddr = $MacAddr.Insert($i,':')
            $i++
        }
    }

    $cmdToVM = @"
#!/bin/bash

                # get interface with given MAC
                __sys_interface=`$(grep -il ${MacAddr} /sys/class/net/*/address)
                if [ 0 -ne `$? ]; then
                    exit 1
                fi
                __sys_interface=`$(basename "`$(dirname "`$__sys_interface")")
                if [ -z "`$__sys_interface" ]; then
                    exit 2
                fi

                echo PingVMs: pinging $pingTargetIpv4 using interface `$__sys_interface >> /root/NET_PRIVATE_NETWORK.log 2>&1
                # ping the remote host using an easily distinguishable pattern
                ping -I `$__sys_interface -c $noPackets -p "cafed00d00766c616e0074616700" $pingTargetIpv4 >> /root/NET_PRIVATE_NETWORK.log 2>&1
                __retVal=`$?

                 if [ "$Test_IPv6" != false ] && [ "$Test_IPv6" = "external" ] ; then
                    echo "Trying to get IPv6 associated with $pingTargetIpv4" >> /root/NET_PRIVATE_NETWORK.log 2>&1
                    full_ipv6=``ssh -i .ssh/$SSH_PRIVATE_KEY -v -o StrictHostKeyChecking=no root@$pingTargetIpv4 "ip addr show | grep -A 2 $pingTargetIpv4 | grep "link"" | awk '{print `$2}'``
                    IPv6=`${full_ipv6:0:`${#full_ipv6}-3}
                    "Trying to ping `$IPv6 on interface `$__sys_interface" >> /root/NET_PRIVATE_NETWORK.log 2>&1
                    # ping the right address
                    ping6 -I `$__sys_interface -c $noPackets "`$IPv6" >> /root/NET_PRIVATE_NETWORK.log 2>&1
                    __retVal=`$(( __retVal && _rVal ))
                fi

                echo PingVMs: ping returned `$__retVal >> /root/NET_PRIVATE_NETWORK.log 2>&1
                exit `$__retVal
"@

    #"pingVMs: sendig command to vm: $cmdToVM"
    $filename = "PingVMs.sh"

    # check for file
    if (Test-Path ".\${filename}")
    {
        Remove-Item ".\${filename}"
    }

    Add-Content $filename "$cmdToVM"

    # send file
    $retVal = SendFileToVM $conIpv4 $sshKey $filename "/root/${$filename}"

    # delete file unless the Leave_trail param was set to yes.
    if ([string]::Compare($leaveTrail, "yes", $true) -ne 0)
    {
        Remove-Item ".\${filename}"
    }

    # check the return Value of SendFileToVM
    if (-not $retVal)
    {
        return $false
    }

    # execute command
    $retVal = SendCommandToVM $conIpv4 $sshKey "cd /root && chmod u+x ${filename} && sed -i 's/\r//g' ${filename} && ./${filename}"

    return $retVal
}


#######################################################################
#
# Main script body
#
#######################################################################

#StopVMViaSSH $vmName $hvServer $sshKey 300

#
# Check input arguments
#
if ($vmName -eq $null)
{
    "Error: VM name is null"
    return $False
}

if ($hvServer -eq $null)
{
    "Error: hvServer is null"
    return $False
}

if ($testParams -eq $null)
{
    "Error: testParams is null"
    return $False
}

# Write out test Params
$testParams

# sshKey used to authenticate ssh connection and send commands
$sshKey = $null

# IP Address of first VM
$ipv4 = $null

# IP Address of second VM
$ipv4VM2 = $null

# Name of second VM
$vm2Name = $null

# name of the switch to which to connect
$netAdapterName = $null

# VM1 IPv4 Address
$vm1StaticIP = $null

# VM2 IPv4 Address
$vm2StaticIP = $null

# Netmask used by both VMs
$netmask = $null

# boolean to leave a trail
$leaveTrail = $null

# switch name
$networkName = $null

#Snapshot name
$snapshotParam = $null

#IP assigned to test interfaces
$tempipv4VM1 = $null
$testipv4VM1 = $null

$tempipv4VM2 = $null
$testipv4VM2 = $null

#External IP address
$failIP1 = $null

#Internal IP address
$failIP2 = $null

#Connection type to switch to
$switch_nic = $null

#Test IPv6
$Test_IPv6 = $null

# change working directory to root dir
$testParams -match "RootDir=([^;]+)"
if (-not $?)
{
    "Mandatory param RootDir=Path; not found!"
    return $false
}
$rootDir = $Matches[1]

if (Test-Path $rootDir)
{
    Set-Location -Path $rootDir
    if (-not $?)
    {
        "Error: Could not change directory to $rootDir !"
        return $false
    }
    "Changed working directory to $rootDir"
}
else
{
    "Error: RootDir = $rootDir is not a valid path"
    return $false
}

$sts = get-module | select-string -pattern HyperV -quiet
if (! $sts)
{
    $HYPERV_LIBRARY = ".\HyperVLibV2SP1\Hyperv.psd1"
    if ( (Test-Path $HYPERV_LIBRARY) )
    {
        Import-module .\HyperVLibV2SP1\Hyperv.psd1
    }
    else
    {
        "Error: The PowerShell HyperV library does not exist"
        return $False
    }
}

# Source TCUitls.ps1 for getipv4 and other functions
if (Test-Path ".\setupScripts\TCUtils.ps1")
{
    . .\setupScripts\TCUtils.ps1
}
else
{
    "Error: Could not find setupScripts\TCUtils.ps1"
    return $false
}

# Source NET_UTILS.ps1 for network functions
if (Test-Path ".\setupScripts\NET_UTILS.ps1")
{
    . .\setupScripts\NET_UTILS.ps1
}
else
{
    "Error: Could not find setupScripts\NET_Utils.ps1"
    return $false
}

$params = $testParams.Split(";")
foreach ($p in $params)
{
    $fields = $p.Split("=")

    switch ($fields[0].Trim())
    {
    "VM2NAME" { $vm2Name = $fields[1].Trim() }
    "SshKey"  { $sshKey  = $fields[1].Trim() }
    "ipv4"    { $ipv4    = $fields[1].Trim() }
    "STATIC_IP" { $vm1StaticIP = $fields[1].Trim() }
    "STATIC_IP2" { $vm2StaticIP = $fields[1].Trim() }
    "PING_FAIL" { $failIP1 = $fields[1].Trim() }
    "PING_FAIL2" { $failIP2 = $fields[1].Trim() }
    "SWITCH" { $switch_nic = $fields[1].Trim() }
    "Test_IPv6" { $Test_IPv6 = $fields[1].Trim() }
    "NETMASK" { $netmask = $fields[1].Trim() }
    "LEAVE_TRAIL" { $leaveTrail = $fields[1].Trim() }
    "SnapshotName" { $SnapshotName = $fields[1].Trim() }
    "NIC"
    {
        $nicArgs = $fields[1].Split(',')
        if ($nicArgs.Length -lt 4)
        {
            "Error: Incorrect number of arguments for NIC test parameter: $p"
            return $false

        }


        $nicType = $nicArgs[0].Trim()
        $networkType = $nicArgs[1].Trim()
        $networkName = $nicArgs[2].Trim()
        $vm1MacAddress = $nicArgs[3].Trim()
        $legacy = $false

        #
        # Validate the network adapter type
        #
        if ("NetworkAdapter" -notcontains $nicType)
        {
            "Error: Invalid NIC type: $nicType . Must be 'NetworkAdapter'"
            return $false
        }

        #
        # Validate the Network type
        #
        if (@("External", "Internal", "Private") -notcontains $networkType)
        {
            "Error: Invalid netowrk type: $networkType .  Network type must be either: External, Internal, Private"
            return $false
        }

        #
        #
        # Make sure the network exists
        #
        $vmSwitch = Get-VMSwitch -VirtualSwitchName $networkName -Server $hvServer
        if (-not $vmSwitch)
        {
            "Error: Invalid network name: $networkName . The network does not exist."
            return $false
        }

        $retVal = isValidMAC $vm1MacAddress

        if (-not $retVal)
        {
            "Invalid Mac Address $vm1MacAddress"
            return $false
        }

        #
        # Get Nic with given MAC Address
        #
        $vm1nic = Get-VMNIC -VM $vmName -Server $hvServer -Legacy:$false | where {$_.Address -eq $vm1MacAddress }
        if ($vm1nic)
        {
            "$vmName found NIC with MAC $vm1MacAddress ."
        }
        else
        {
            "Error: $vmName - No NIC found with MAC $vm1MacAddress ."
            return $false
        }
    }
    default   {}  # unknown param - just ignore it
    }
}

if (-not $vm2Name)
{
    "Error: test parameter vm2Name was not specified"
    return $False
}

# make sure vm2 is not the same as vm1
if ("$vm2Name" -like "$vmName")
{
    "Error: vm2 must be different from the test VM."
    return $false
}

if (-not $sshKey)
{
    "Error: test parameter sshKey was not specified"
    return $False
}

if (-not $ipv4)
{
    "Error: test parameter ipv4 was not specified"
    return $False
}

#set the parameter for the snapshot
$snapshotParam = "SnapshotName = ${SnapshotName}"

#revert VM2
.\setupScripts\RevertSnapshot.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $snapshotParam
Start-sleep -s 5

#
# Verify the VMs exists
#
$vm1 = Get-VM -Name $vmName -Server $hvServer -ErrorAction SilentlyContinue
if (-not $vm1)
{
    "Error: VM ${vmName} does not exist"
    return $False
}

$vm2 = Get-VM -Name $vm2Name -Server $hvServer -ErrorAction SilentlyContinue
if (-not $vm2)
{
    "Error: VM ${vm2Name} does not exist"
    return $False
}

# hold testParam data for NET_ADD_NIC_MAC script
$vm2testParam = $null
$vm2MacAddress = $null

# remember if we added the NIC or it was already there.
$scriptAddedNIC = $false

# Check for a NIC of the given network type on VM2
$vm2nic = $null
$nic2 = Get-VMNIC -VM $vm2Name -Server $hvServer -Legacy:$false | where { $_.SwitchName -like "$networkName" }


for ($i = 0 ; $i -lt 3; $i++)
{
   $vm2MacAddress = getRandUnusedMAC $hvServer
   if ($vm2MacAddress)
   {
        break
   }
}
$retVal = isValidMAC $vm2MacAddress
if (-not $retVal)
{
    "Could not find a valid MAC for $vm2Name. Received $vm2MacAddress"
    return $false
}

#construct NET_ADD_NIC_MAC Parameter
$vm2testParam = "NIC=NetworkAdapter,$networkType,$networkName,$vm2MacAddress"

if ( Test-Path ".\setupscripts\NET_ADD_NIC_MAC.ps1")
{
    # Make sure VM2 is shutdown
    if (Get-VM -Name $vm2Name |  Where { $_.State -like "Running" })
    {
        Stop-VM $vm2Name -force

        if (-not $?)
        {
            "Error: Unable to shut $vm2Name down (in order to add a new network Adapter)"
            return $false
        }

        # wait for VM to finish shutting down
        $timeout = 60
        while (Get-VM -Name $vm2Name |  Where { $_.State -notlike "Off" })
        {
            if ($timeout -le 0)
            {
                "Error: Unable to shutdown $vm2Name"
                return $false
            }

            start-sleep -s 5
            $timeout = $timeout - 5
        }

    }

    .\setupscripts\NET_ADD_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams $vm2testParam
}
else
{
    "Error: Could not find setupScripts\NET_ADD_NIC_MAC.ps1 ."
    return $false
}

if (-Not $?)
{
    "Error: Cannot add new NIC to $vm2Name"
    return $false
}

# get the newly added NIC
$vm2nic = Get-VMNIC -VM $vm2Name -Server $hvServer -Legacy:$false | where { $_.Address -like "$vm2MacAddress" }

if (-not $vm2nic)
{
    "Error: Could not retrieve the newly added NIC to VM2"
    return $false
}

$scriptAddedNIC = $true


"Tests Private network"

if (-not $netmask)
{
    $netmask = 255.255.255.0
}


if (-not $vm1StaticIP)
{
    $vm1StaticIP = getAddress "10.10.10.10" $netmask 1
}

# compute another ipv4 address for vm2
if (-not $vm2StaticIP)
{
    [int]$nth = 2
    do
    {
        $vm2StaticIP = getAddress $vm1StaticIP $netmask $nth
        $nth += 1
    } while ($vm2StaticIP -like $vm1StaticIP)

}
else
{
    # make sure $vm2StaticIP is in the same subnet as $vm1StaticIP
    $retVal = containsAddress $vm1StaticIP $netmask $vm2StaticIP

    if (-not $retVal)
    {
        "$vm2StaticIP is not in the same subnet as $vm1StaticIP / $netmask"
        return $false
    }
}


#
# LIS Started VM1, so start VM2
#

if (Get-VM -Name $vm2Name |  Where { $_.State -notlike "Running" })
{
    Start-VM -VM $vm2Name -Server $hvServer
    if (-not $?)
    {
        "Error: Unable to start VM ${vm2Name}"
        $error[0].Exception
        return $False
    }
}

$timeout = 200 # seconds
if (-not (WaitForVMToStartKVP $vm2Name $hvServer $timeout))
{
    "Warning: $vm2Name never started KVP"
}

# get vm2 ipv4

$vm2ipv4 = GetIPv4 $vm2Name $hvServer

"netmask = $netmask"

# wait for ssh to startg
$timeout = 120 #seconds
if (-not (WaitForVMToStartSSH $vm2ipv4 $timeout))
{
    "Error: VM ${vm2Name} never started"
    Stop-VM $vm2Name -Server $hvServer -force | out-null
    return $False
}

# send utils.sh to VM2
if (-not (Test-Path ".\remote-scripts\ica\utils.sh"))
{
    "Error: Unable to find remote-scripts\ica\utils.sh "
    return $false
}

"Sending .\remote-scripts\ica\utils.sh to $vm2ipv4 , authenticating with $sshKey"
$retVal = SendFileToVM "$vm2ipv4" "$sshKey" ".\remote-scripts\ica\utils.sh" "/root/utils.sh"

if (-not $retVal)
{
    "Failed sending file to VM!"
    return $False
}

"Successfully sent utils.sh"


#switch network connection type in case is needed
if ($switch_nic)
{
    $retVal = .\setupscripts\NET_SWITCH_NIC_MAC.ps1 -vmName $vmName -hvServer $hvServer -testParams "SWITCH=$switch_nic"
    if (-not $retVal)
    {
        "Failed to switch connection type for $vmName on $hvServer with $switch_nic"
        return $False
    }

    $retVal = .\setupscripts\NET_SWITCH_NIC_MAC.ps1 -vmName $vm2Name -hvServer $hvServer -testParams "SWITCH=NetworkAdapter,Private,Private,$vm2MacAddress"
    if (-not $retVal)
    {
        "Failed to switch connection type for $vm2Name"
        return $False
    }

    "Successfully switched connection type for both VMs"
}

"Configuring test interface (${vm1MacAddress}) on $vmName (${ipv4}) "

# send ifcfg file to each VM
$retVal = CreateInterfaceConfig $ipv4 $sshKey $vm1MacAddress $vm1StaticIP $netmask
if (-not $retVal)
{
    "Failed to create Interface-File on vm $ipv4 for interface with mac $vm1MacAddress, by setting a static IP of $vm1StaticIP netmask $netmask"
    return $false
}

"Successfully configured interface"

"Configuring test interface (${vm2MacAddress}) on $vm2Name (${vm2ipv4}) "
$retVal = CreateInterfaceConfig $vm2ipv4 $sshKey $vm2MacAddress $vm2StaticIP $netmask
if (-not $retVal)
{
    "Failed to create Interface File on vm $vm2ipv4 for interface with mac $vm2MacAddress, by setting a static IP of $vm2StaticIP netmask $netmask"
    return $false
}

#get the ipv4 of the test adapter allocated by DHCP

start-sleep 20

"sshKey   = ${sshKey}"
"vm1 Name = ${vmName}"
"vm1 ipv4 = ${ipv4}"
"vm1 MAC = ${vm1MacAddress}"

"vm2 Name = ${vm2Name}"
"vm2 ipv4 = ${vm2ipv4}"
"vm2 MAC = ${vm2MacAddress}"


# Try to ping with the private network interfaces
"Trying to ping from vm1 with mac $vm1MacAddress to $vm2StaticIP "
# try to ping
$retVal = pingVMs $ipv4 $vm2StaticIP $sshKey 10 $vm1MacAddress

if (-not $retVal)
{
    "Unable to ping $vm2StaticIP from $vm1StaticIP with MAC $vm1MacAddress"
    return $false
}

"Successfully pinged"

"Trying to ping from vm2 with mac $vm2MacAddress to $vm1StaticIP "
$retVal = pingVMs $vm2ipv4 $vm1StaticIP $sshKey 10 $vm2MacAddress

if (-not $retVal)
{
    "Unable to ping $vm1StaticIP from $vm2StaticIP with MAC $vm2MacAddress"
    return $false
}

"Successfully pinged"

# Try to ping external network with the private network interfaces. This should fail
"Trying to ping from vm1 with mac $vm1MacAddress to $failIP1 "
# try to ping
$retVal = pingVMs $ipv4 $failIP1 $sshKey 10 $vm1MacAddress

if ($retVal)
{
    "Ping from vm1: Able to ping $failIP1 from $vm1StaticIP with MAC $vm2MacAddress although it should not have worked!"
    return $false
}

"Failed to ping (as expected)"

"Trying to ping from vm1 with mac $vm2MacAddress to $failIP2 "
# try to ping
$retVal = pingVMs $vm2ipv4 $failIP2 $sshKey 10 $vm1MacAddress

if ($retVal)
{
    "Ping from vm2: Able to ping $failIP2 from $vm2StaticIP with MAC $vm2MacAddress although it should not have worked!"
    return $false
}

"Failed to ping (as expected)"

"Stopping $vm2Name"
Stop-VM -Name $vm2Name -force

if (-not $?)
{
    "Warning: Unable to shut down $vm2Name"
}

"Test successful!"

return $true