function New-AzurePIMRequest {
    [CmdletBinding()]
    param (
        [int]$DurationInHours = 8,
        $RoleName = 'Contributor',
        $ResourceType = 'ManagementGroup',
        $ResourceName = 'IT',
        $Reason = "Daily PIM elevation"
    )


    if (-not (Get-Module -ListAvailable -Name AzureADPreview)) {

        Write-Host 'Azure AD Preview module required, installing' -ForegroundColor Yellow

        Install-Module -Name AzureADPreview -Scope CurrentUser -AllowClobber

        if (Get-Module -Name AzureAD) {

            Remove-Module -Name AzureAD
            Import-Module -Name AzureADPreview

        } else {

            Import-Module -Name AzureADPreview

        }

    } else {

        if (Get-Module -Name AzureAD) {

            Remove-Module -Name AzureAD
            Import-Module -Name AzureADPreview

        } else {

            Import-Module -Name AzureADPreview

        }


    }


    # Needed for activating roles enforcing MFA
    if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {

        Write-Host 'MSAL.PS module required, installing' -ForegroundColor Yellow

        Install-Module -Name MSAL.PS -Scope CurrentUser -AllowClobber -AcceptLicense

    }


    try {

        $AzureADCurrentSessionInfo = AzureADPreview\Get-AzureADCurrentSessionInfo -ErrorAction Stop

    }

    catch {

        Write-Host 'No active Azure AD session, calling Connect-AzureAD (the login window often hides in the backgroud, minimize the PowerShell window to check if you do not see it)' -ForegroundColor Yellow

        AzureADPreview\Connect-AzureAD
        $AzureADCurrentSessionInfo = AzureADPreview\Get-AzureADCurrentSessionInfo

    }

    switch ($ResourceType) {
        'resourcegroup' { $resource = AzureADPreview\Get-AzureADMSPrivilegedResource -ProviderId AzureResources -Filter "Type eq 'resourcegroup'" | Where-Object DisplayName -eq $ResourceName }
        'managementgroup' { $resource = AzureADPreview\Get-AzureADMSPrivilegedResource -ProviderId AzureResources -Filter "Type eq 'managementgroup'" | Where-Object DisplayName -eq $ResourceName }
        'subscription' { $resource = AzureADPreview\Get-AzureADMSPrivilegedResource -Provider azureResources -Filter "Type eq 'subscription'" | Where-Object DisplayName -eq $ResourceName }
        Default { $resource = AzureADPreview\Get-AzureADMSPrivilegedResource -Provider azureResources | Out-GridView -PassThru }
    }

    switch ($RoleName) {
        'Owner' { $roleDefinition = AzureADPreview\Get-AzureADMSPrivilegedRoleDefinition -ProviderId azureResources -ResourceId $resource.Id -Filter "DisplayName eq 'Owner'" }
        'Contributor' { $roleDefinition = AzureADPreview\Get-AzureADMSPrivilegedRoleDefinition -ProviderId azureResources -ResourceId $resource.Id -Filter "DisplayName eq 'Contributor'" }
        Default { $roleDefinition = AzureADPreview\Get-AzureADMSPrivilegedRoleDefinition -ProviderId azureResources -ResourceId $resource.Id | Out-GridView -PassThru }
    }

    $subject = AzureADPreview\Get-AzureADUser -Filter ("userPrincipalName eq" + "'" + $($AzureADCurrentSessionInfo.Account) + "'")

    $schedule = New-Object Microsoft.Open.MSGraph.Model.AzureADMSPrivilegedSchedule
    $schedule.Type = "Once"
    $schedule.StartDateTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $schedule.EndDateTime = (Get-Date).AddHours($DurationInHours).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    $ExistingRoleAssignmentRequest = AzureADPreview\Get-AzureADMSPrivilegedRoleAssignmentRequest -ProviderId azureResources | Where-Object RequestedDateTime -gt (Get-Date).AddHours(-8) | Where-Object ResourceId -eq $resource.Id | Where-Object RoleDefinitionId -eq $roleDefinition.Id | Where-Object {$PSItem.Status.Status -ne 'Closed'}

    if ($ExistingRoleAssignmentRequest) {

        Write-Host "User $($AzureADCurrentSessionInfo.Account) is already elevated" -ForegroundColor Yellow

    } else {

        try {

            AzureADPreview\Open-AzureADMSPrivilegedRoleAssignmentRequest -ProviderId azureResources -Schedule $schedule -ResourceId $resource.Id -RoleDefinitionId $roleDefinition.Id -SubjectId $subject.ObjectId -AssignmentState "Active" -Type "UserAdd" -Reason $Reason -ErrorAction Stop

            Write-Host "PIM elevation for user $($AzureADCurrentSessionInfo.Account) succeeded" -ForegroundColor Green

        } catch {

            # Credit for MFA activation-section: http://www.anujchaudhary.com/2020/02/connect-to-azure-ad-powershell-with-mfa.html

            if ($PSItem.Exception.Message -Like "*MfaRule*") {

                Write-Host "PIM elevation for user $($AzureADCurrentSessionInfo.Account) failed due to MFA activation requirement for role $RoleName - re-trying with MFA authencation)" -ForegroundColor Yellow
                Write-Host 'Calling Get-MSALToken (the login window often hides in the backgroud, minimize the PowerShell window to check if you do not see it)' -ForegroundColor Yellow

                try {
                    # Get token for MS Graph by prompting for MFA (note: ClientId 1b730954-1685-4b74-9bfd-dac224a7b894 = Azure PowerShell)
                    $MsResponse = Get-MSALToken -Scopes @("https://graph.microsoft.com/.default") -ClientId "1b730954-1685-4b74-9bfd-dac224a7b894" -RedirectUri "urn:ietf:wg:oauth:2.0:oob" -Authority "https://login.microsoftonline.com/common" -Interactive -ExtraQueryParameters @{claims = '{"access_token" : {"amr": { "values": ["mfa"] }}}' } -ErrorAction Stop

                    # Get token for AAD Graph
                    $AadResponse = Get-MSALToken -Scopes @("https://graph.windows.net/.default") -ClientId "1b730954-1685-4b74-9bfd-dac224a7b894" -RedirectUri "urn:ietf:wg:oauth:2.0:oob" -Authority "https://login.microsoftonline.com/common" -ErrorAction Stop

                    AzureADPreview\Connect-AzureAD -AadAccessToken $AadResponse.AccessToken -MsAccessToken $MsResponse.AccessToken -AccountId: $AzureADCurrentSessionInfo.Account.Id -tenantId: $AzureADCurrentSessionInfo.TenantId.Guid -ErrorAction Stop

                    AzureADPreview\Open-AzureADMSPrivilegedRoleAssignmentRequest -ProviderId aadRoles -Schedule $schedule -ResourceId $AzureADCurrentSessionInfo.TenantId -RoleDefinitionId $roleDefinition.Id -SubjectId $subject.ObjectId -AssignmentState "Active" -Type "UserAdd" -Reason $Reason -ErrorAction Stop
                }

                catch {

                    Write-Host "PIM elevation for user $($AzureADCurrentSessionInfo.Account) failed: $($PSItem.Exception.Message)" -ForegroundColor Red

                }
            } else {

            Write-Host "PIM elevation for user $($AzureADCurrentSessionInfo.Account) failed: $($PSItem.Exception.Message)" -ForegroundColor Red

            }
        }
    }
}