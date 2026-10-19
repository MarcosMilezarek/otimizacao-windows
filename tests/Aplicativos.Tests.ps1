# Testes que alteram o sistema: executar SOMENTE na VM de teste (tools\Testar-NaVM.ps1 define OTIMIZACAO_VM=1).
BeforeAll {
    if ($env:OTIMIZACAO_VM -ne '1') { throw 'Aplicativos.Tests.ps1 só pode rodar na VM de teste (OTIMIZACAO_VM=1).' }
    # -Perfil obrigatório: valor fictício só para o binding; com dot-source o script não executa.
    . (Join-Path $PSScriptRoot '..\src\Aplicativos.ps1') -Perfil 'nao-usado.psd1'
    $script:raizSessoes = Join-Path $env:TEMP ('sessoes-' + [guid]::NewGuid())
    function New-SessaoTeste { New-SessaoOtimizacao -Cliente T -Script Aplicativos -Raiz $script:raizSessoes }
    function Invoke-ReversaoTeste {
        param($Aplicada)
        $alvo = Get-SessaoParaReverter -Cliente T -Script Aplicativos -Pasta $Aplicada.Pasta -Raiz $script:raizSessoes
        $sr = New-SessaoTeste
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        $sr
    }
    function Get-Linha { param($S, [string]$Item) @($S.Linhas | Where-Object Item -eq $Item) }
    function Get-Falha { param($S) (@($S.Linhas | Where-Object Resultado -eq 'Falha').Detalhe -join '; ') }
    function New-PerfilA { param([hashtable]$Protegidos = @{}, [hashtable]$Opcoes = @{}) [pscustomobject]@{ Protegidos = $Protegidos; Opcoes = $Opcoes } }
    function Get-EstadoAppx {
        <# Nomes instalados (todos os usuários) e provisionados, para provar que só o alvo foi removido. #>
        @(@(Get-AppxPackage -AllUsers | ForEach-Object { "I:$($_.PackageFullName)" }) + @(Get-AppxProvisionedPackage -Online | ForEach-Object { "P:$($_.PackageName)" }) | Sort-Object)
    }

    function New-MsiTeste {
        <#
            MSI mínimo, sem arquivos, criado pela API de automação do Windows Installer: grava HKLM\SOFTWARE\OtimizacaoFixture\Instalado
            e registra o produto em Programas e Recursos. Serve para provar o msiexec /x real.
        #>
        param([string]$Caminho, [string]$ProductCode, [string]$Nome)
        $inv = { param($o, [string]$m, [string]$tipo, [object[]]$a) $o.GetType().InvokeMember($m, $tipo, $null, $o, $a) }
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = & $inv $wi 'OpenDatabase' 'InvokeMethod' @($Caminho, 3)
        $sql = @(
            'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` LONGCHAR NOT NULL LOCALIZABLE PRIMARY KEY `Property`)'
            'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Directory`)'
            'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `ComponentId` CHAR(38), `Directory_` CHAR(72) NOT NULL, `Attributes` SHORT NOT NULL, `Condition` CHAR(255), `KeyPath` CHAR(72) PRIMARY KEY `Component`)'
            'CREATE TABLE `Feature` (`Feature` CHAR(38) NOT NULL, `Feature_Parent` CHAR(38), `Title` CHAR(64) LOCALIZABLE, `Description` CHAR(255) LOCALIZABLE, `Display` SHORT, `Level` SHORT NOT NULL, `Directory_` CHAR(72), `Attributes` SHORT NOT NULL PRIMARY KEY `Feature`)'
            'CREATE TABLE `FeatureComponents` (`Feature_` CHAR(38) NOT NULL, `Component_` CHAR(72) NOT NULL PRIMARY KEY `Feature_`, `Component_`)'
            'CREATE TABLE `Registry` (`Registry` CHAR(72) NOT NULL, `Root` SHORT NOT NULL, `Key` CHAR(255) NOT NULL LOCALIZABLE, `Name` CHAR(255) LOCALIZABLE, `Value` LONGCHAR LOCALIZABLE, `Component_` CHAR(72) NOT NULL PRIMARY KEY `Registry`)'
            # RegisterProduct lê a tabela Media mesmo sem arquivos (erro 2228 sem ela).
            'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` SHORT NOT NULL, `DiskPrompt` CHAR(64) LOCALIZABLE, `Cabinet` CHAR(255), `VolumeLabel` CHAR(32), `Source` CHAR(72) PRIMARY KEY `DiskId`)'
            "INSERT INTO ``Media`` (``DiskId``, ``LastSequence``) VALUES (1, 0)"
            'CREATE TABLE `InstallExecuteSequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)'
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductCode', '$ProductCode')"
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductName', '$Nome')"
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductVersion', '1.0.0')"
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('Manufacturer', 'Fixture Otimizacao')"
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductLanguage', '1033')"
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('UpgradeCode', '{$([guid]::NewGuid().ToString().ToUpper())}')"
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ALLUSERS', '1')"
            "INSERT INTO ``Directory`` (``Directory``, ``Directory_Parent``, ``DefaultDir``) VALUES ('TARGETDIR', '', 'SourceDir')"
            # 260 = 64 bits (256) + KeyPath no registro (4)
            "INSERT INTO ``Component`` (``Component``, ``ComponentId``, ``Directory_``, ``Attributes``, ``Condition``, ``KeyPath``) VALUES ('Principal', '{$([guid]::NewGuid().ToString().ToUpper())}', 'TARGETDIR', 260, '', 'RegFixture')"
            "INSERT INTO ``Feature`` (``Feature``, ``Feature_Parent``, ``Title``, ``Description``, ``Display``, ``Level``, ``Directory_``, ``Attributes``) VALUES ('Principal', '', 'Principal', '', 1, 1, 'TARGETDIR', 0)"
            "INSERT INTO ``FeatureComponents`` (``Feature_``, ``Component_``) VALUES ('Principal', 'Principal')"
            "INSERT INTO ``Registry`` (``Registry``, ``Root``, ``Key``, ``Name``, ``Value``, ``Component_``) VALUES ('RegFixture', 2, 'SOFTWARE\OtimizacaoFixture', 'Instalado', '#1', 'Principal')"
        )
        $seq = [ordered]@{ CostInitialize = 800; FileCost = 900; CostFinalize = 1000; InstallValidate = 1400; InstallInitialize = 1500; ProcessComponents = 1600
            UnpublishFeatures = 1800; RemoveRegistryValues = 2600; WriteRegistryValues = 5000; RegisterProduct = 6100; PublishFeatures = 6300; PublishProduct = 6400; InstallFinalize = 6600 }
        foreach ($a in $seq.Keys) { $sql += "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Sequence``) VALUES ('$a', $($seq[$a]))" }
        foreach ($q in $sql) {
            $v = & $inv $db 'OpenView' 'InvokeMethod' @($q)
            & $inv $v 'Execute' 'InvokeMethod' @() | Out-Null
            & $inv $v 'Close' 'InvokeMethod' @() | Out-Null
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($v)
        }
        $si = & $inv $db 'SummaryInformation' 'GetProperty' @(20)
        foreach ($par in @(@(2, 'Fixture Otimizacao'), @(7, 'x64;1033'), @(9, "{$([guid]::NewGuid().ToString().ToUpper())}"), @(14, 200), @(15, 2))) {
            & $inv $si 'Property' 'SetProperty' $par | Out-Null
        }
        & $inv $si 'Persist' 'InvokeMethod' @() | Out-Null
        & $inv $db 'Commit' 'InvokeMethod' @() | Out-Null
        foreach ($o in $si, $db, $wi) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
}
AfterAll { Remove-Item $script:raizSessoes -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Proteções' {
    It '<Caso>' -ForEach @(
        @{ Caso = 'Assistência Rápida nunca sai'; Nome = 'Quick Assist'; Id = 'MicrosoftCorporationII.QuickAssist'; Fab = 'Microsoft Corp.'; A2 = $false; Esperado = '*nunca*' }
        @{ Caso = 'Teams novo nunca sai'; Nome = 'Microsoft Teams'; Id = 'MSTeams'; Fab = 'Microsoft'; A2 = $false; Esperado = '*nunca*' }
        @{ Caso = 'Dell Command | Update é ferramenta de driver'; Nome = 'Dell Command | Update'; Id = '{X}'; Fab = 'Dell Inc.'; A2 = $true; Esperado = '*driver*' }
        @{ Caso = 'Lenovo Vantage é ferramenta de driver'; Nome = 'Lenovo Vantage'; Id = 'E046963F.LenovoCompanion'; Fab = 'LENOVO INC.'; A2 = $true; Esperado = '*driver*' }
        @{ Caso = 'HP Support Assistant (Appx) é ferramenta de driver'; Nome = 'x'; Id = 'AD2F1837.HPSupportAssistant'; Fab = 'HP Inc.'; A2 = $true; Esperado = '*driver*' }
        @{ Caso = 'Programa da Microsoft fora do A2'; Nome = 'Microsoft Edge'; Id = 'Microsoft Edge'; Fab = 'Microsoft Corporation'; A2 = $true; Esperado = '*Microsoft*' }
        @{ Caso = 'Protegido no perfil por curinga'; Nome = 'Contoso Fiscal'; Id = '{Y}'; Fab = 'Contoso'; A2 = $true; Esperado = '*Protegido*' }
        @{ Caso = 'Programa comum do fabricante é permitido'; Nome = 'Fabricante Promo'; Id = '{Z}'; Fab = 'Fabricante'; A2 = $true; Esperado = $null }
    ) {
        $perfil = New-PerfilA -Protegidos @{ Aplicativos = @('Contoso*') }
        $m = Get-MotivoProibido -Programa ([pscustomobject]@{ Nome = $Nome; Id = $Id; Fabricante = $Fab }) -Perfil $perfil -A2:$A2
        if ($Esperado) { $m | Should -BeLike $Esperado } else { $m | Should -BeNullOrEmpty }
    }

    It 'Lista do A1 não contém app da lista de nunca remover nem o Teams novo' {
        @($script:ListaA1 | Where-Object { $script:NuncaRemover -contains $_ }).Count | Should -Be 0
        $script:ListaA1 | Should -Not -Contain 'MSTeams'
        $script:PacoteA4 | Should -Be 'MicrosoftTeams'
    }
}

Describe 'Appx (A1 e A4)' {
    It 'Nome de exibição resolvido do manifesto (ms-resource) no idioma do Windows' {
        $p = Get-AppxPackage -AllUsers -Name 'Clipchamp.Clipchamp'
        (Get-NomeExibicaoAppx -Pacote $p).Nome | Should -Be 'Microsoft Clipchamp'
        (Get-NomeExibicaoAppx -Pacote (Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsCamera')).Nome | Should -Be 'Windows Camera'
    }

    It 'Simulação lista pacotes, tamanho e usuários e não remove' {
        $s = New-SessaoOtimizacao -Cliente T -Script Aplicativos -Simular
        Invoke-A1 -Sessao $s -Perfil (New-PerfilA) -Loja $true -Lista @('Microsoft.BingWeather')
        $l = Get-Linha $s 'A1'
        $l.Resultado | Should -Be 'Simulado'
        $l.ValorAnterior | Should -BeLike '*Microsoft.BingWeather_*provisionado: Microsoft.BingWeather_*'
        $l.Detalhe | Should -BeLike '* MB; instalado para:*cliente*'
        @(Get-AppxPackage -AllUsers -Name 'Microsoft.BingWeather').Count | Should -BeGreaterThan 0
    }

    It 'Remove para todos os usuários e o provisionamento, só o alvo, e é idempotente' {
        $antes = Get-EstadoAppx
        $s = New-SessaoTeste
        Invoke-A1 -Sessao $s -Perfil (New-PerfilA) -Loja $true -Lista @('Microsoft.BingWeather')
        Get-Falha $s | Should -BeNullOrEmpty
        (Get-Linha $s 'A1').Resultado | Should -Be 'OK'
        $depois = Get-EstadoAppx
        @(Get-AppxPackage -AllUsers -Name 'Microsoft.BingWeather').Count | Should -Be 0
        @(Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq 'Microsoft.BingWeather').Count | Should -Be 0
        @(Compare-Object $antes $depois | ForEach-Object { $_.InputObject } | Where-Object { $_ -notlike '*Microsoft.BingWeather_*' }).Count | Should -Be 0
        $e = @(Get-Content (Join-Path $s.Pasta 'estado-original.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
        $e[0].Pfn | Should -Be 'Microsoft.BingWeather_8wekyb3d8bbwe'
        $e[0].NomeExibicao | Should -Be 'MSN Weather'
        $script:sessaoA1 = $s

        $s2 = New-SessaoTeste
        Invoke-A1 -Sessao $s2 -Perfil (New-PerfilA) -Loja $true -Lista @('Microsoft.BingWeather')
        (Get-Linha $s2 'A1').Resultado | Should -Be 'JaAplicado'
    }

    It 'Reversão sem reinstalação: Pulado com nome e link da Store, sem Falha' {
        $sr = Invoke-ReversaoTeste -Aplicada $script:sessaoA1
        Get-Falha $sr | Should -BeNullOrEmpty
        $l = Get-Linha $sr 'A1'
        $l.Resultado | Should -Be 'Pulado'
        $l.Detalhe | Should -BeLike "*buscar 'MSN Weather'*ms-windows-store://pdp/?PFN=Microsoft.BingWeather_8wekyb3d8bbwe*"
        Test-Path (Join-Path $script:sessaoA1.Pasta 'revertido.txt') | Should -BeTrue
    }

    It 'Reversão de pacote presente: Revertido' {
        $sr = New-SessaoTeste
        $alvo = [pscustomobject]@{ Pasta = $TestDrive; Entradas = @([pscustomobject]@{ Tipo = 'AppxRemovido'; Item = 'A1'; Nome = 'Microsoft.BingNews'; NomeExibicao = 'Microsoft News'; Pfn = 'Microsoft.BingNews_8wekyb3d8bbwe' }) }
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        (Get-Linha $sr 'A1').Resultado | Should -Be 'Revertido'
    }

    It 'Reversão simulada não consulta nem altera' {
        Mock Get-AppxPackage { throw 'não deveria ser chamado' }
        $sr = New-SessaoOtimizacao -Cliente T -Script Aplicativos -Simular
        $alvo = [pscustomobject]@{ Pasta = $TestDrive; Entradas = @([pscustomobject]@{ Tipo = 'AppxRemovido'; Item = 'A1'; Nome = 'Microsoft.BingNews'; NomeExibicao = 'x'; Pfn = 'y' }) }
        Invoke-Reversao -Sessao $sr -Alvo $alvo -Manipuladores (Get-ManipuladorReversao)
        (Get-Linha $sr 'A1').Resultado | Should -Be 'Simulado'
    }

    It 'Protegidos.Aplicativos por <Tipo>: pulado e mantido' -ForEach @(
        @{ Tipo = 'nome do pacote'; Padrao = 'Microsoft.BingNews' }
        @{ Tipo = 'nome de exibição'; Padrao = 'Microsoft News' }
    ) {
        $s = New-SessaoTeste
        Invoke-A1 -Sessao $s -Perfil (New-PerfilA -Protegidos @{ Aplicativos = @($Padrao) }) -Loja $true -Lista @('Microsoft.BingNews')
        (Get-Linha $s 'A1').Detalhe | Should -Be 'Protegido no perfil.'
        @(Get-AppxPackage -AllUsers -Name 'Microsoft.BingNews').Count | Should -BeGreaterThan 0
    }

    It '<Nome> recusado: <Motivo>' -ForEach @(
        @{ Nome = 'Microsoft.WindowsStore'; Motivo = '*nunca*' }
        @{ Nome = 'Microsoft.Windows.ShellExperienceHost'; Motivo = '*sistema*' }
        @{ Nome = 'MSTeams'; Motivo = '*nunca*' }
    ) {
        $s = New-SessaoTeste
        Remove-PacoteAppx -Sessao $s -Item 'A2' -Nome $Nome -Perfil (New-PerfilA) -Loja $true
        $l = Get-Linha $s 'A2'
        $l.Resultado | Should -Be 'Pulado'
        $l.Detalhe | Should -BeLike $Motivo
        @(Get-AppxPackage -AllUsers -Name $Nome).Count | Should -BeGreaterThan 0
    }

    It 'Sem Microsoft Store: pulado e mantido' {
        $s = New-SessaoTeste
        Invoke-A1 -Sessao $s -Perfil (New-PerfilA) -Loja $false -Lista @('Microsoft.BingNews')
        (Get-Linha $s 'A1').Detalhe | Should -BeLike '*Store não instalada*'
        @(Get-AppxPackage -AllUsers -Name 'Microsoft.BingNews').Count | Should -BeGreaterThan 0
        Test-LojaDisponivel | Should -BeTrue
    }

    It 'A4 na 26300 sem Teams pessoal: JaAplicado e Teams novo intacto' {
        $antes = @(Get-AppxPackage -AllUsers -Name 'MSTeams').Count
        $s = New-SessaoTeste
        Invoke-A4 -Sessao $s -Perfil (New-PerfilA) -Loja $true
        (Get-Linha $s 'A4').Resultado | Should -Be 'JaAplicado'
        @(Get-AppxPackage -AllUsers -Name 'MSTeams').Count | Should -Be $antes
    }

    It 'A4 com Teams pessoal (mock): remove só MicrosoftTeams' {
        $marca = Join-Path $TestDrive 'teams-removido'
        Mock Get-PacoteAppx -ParameterFilter { $Nome -eq 'MicrosoftTeams' } {
            if (Test-Path -LiteralPath (Join-Path $TestDrive 'teams-removido')) { return [pscustomobject]@{ Instalados = @(); Provisionados = @() } }
            [pscustomobject]@{
                Instalados    = @([pscustomobject]@{ Name = 'MicrosoftTeams'; PackageFullName = 'MicrosoftTeams_23285.3604.2469.4152_x64__8wekyb3d8bbwe'; PackageFamilyName = 'MicrosoftTeams_8wekyb3d8bbwe'; Version = '23285.3604.2469.4152'; InstallLocation = $null; NonRemovable = $false; IsFramework = $false; SignatureKind = 'Store'; PackageUserInformation = @() })
                Provisionados = @()
            }
        }
        Mock Get-NomeExibicaoAppx { [pscustomobject]@{ Nome = 'Microsoft Teams (pessoal)'; Fabricante = 'Microsoft Corporation' } }
        Mock Remove-AppxPackage { New-Item -ItemType File (Join-Path $TestDrive 'teams-removido') -Force | Out-Null }
        $s = New-SessaoTeste
        Invoke-A4 -Sessao $s -Perfil (New-PerfilA) -Loja $true
        (Get-Linha $s 'A4').Resultado | Should -Be 'OK' -Because (Get-Falha $s)
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly -ParameterFilter { $Package -like 'MicrosoftTeams_*' -and $AllUsers }
        Test-Path $marca | Should -BeTrue
    }

    It 'Falha num pacote não interrompe os demais' {
        Mock Remove-PacoteAppx -ParameterFilter { $Nome -eq 'pacote.falha' } { throw 'erro simulado' }
        Mock Remove-PacoteAppx -ParameterFilter { $Nome -ne 'pacote.falha' } { Write-LogOtimizacao -Sessao $Sessao -Item 'A1' -Alvo $Nome -Resultado JaAplicado | Out-Null }
        $s = New-SessaoTeste
        Invoke-A1 -Sessao $s -Perfil (New-PerfilA) -Loja $true -Lista @('pacote.falha', 'pacote.ok')
        @(Get-Linha $s 'A1' | Where-Object Resultado -eq 'Falha').Count | Should -Be 1
        (Get-Linha $s 'A1' | Where-Object Alvo -eq 'pacote.ok').Resultado | Should -Be 'JaAplicado'
    }
}

Describe 'A2 programas do fabricante' {
    BeforeAll {
        $script:pc = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
        $script:msi = Join-Path $TestDrive 'fixture.msi'
        $script:nomeMsi = 'Fixture Otimizacao MSI'
        New-MsiTeste -Caminho $script:msi -ProductCode $script:pc -Nome $script:nomeMsi
        function Install-MsiTeste {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$script:msi`"", '/qn', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "Instalação da fixture MSI falhou: $($p.ExitCode)" }
        }
        Install-MsiTeste
        $script:un = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        foreach ($f in @(
                @{ Chave = 'OtimizacaoFixtureExe'; Nome = 'Fixture Otimizacao EXE'; Fab = 'Fixture Otimizacao' }
                @{ Chave = 'OtimizacaoFixtureDell'; Nome = 'Dell Command | Update'; Fab = 'Dell Inc.' }
            )) {
            New-Item "$script:un\$($f.Chave)" -Force | Out-Null
            New-ItemProperty "$script:un\$($f.Chave)" -Name DisplayName -Value $f.Nome -Force | Out-Null
            New-ItemProperty "$script:un\$($f.Chave)" -Name Publisher -Value $f.Fab -Force | Out-Null
            New-ItemProperty "$script:un\$($f.Chave)" -Name UninstallString -Value 'C:\Fixture\unins000.exe' -Force | Out-Null
        }
    }
    AfterAll {
        Remove-Item "$script:un\OtimizacaoFixtureExe", "$script:un\OtimizacaoFixtureDell" -Force -ErrorAction SilentlyContinue
        if (Test-ProdutoMsiPresente -ProductCode $script:pc) { Start-Process msiexec.exe -ArgumentList @('/x', $script:pc, '/qn') -Wait }
    }

    It 'Fixture instalada: listada como MSI com ProductCode e tamanho, valor gravado pelo MSI presente' {
        $p = @(Get-ProgramaMaquina | Where-Object Nome -eq $script:nomeMsi)
        $p.Count | Should -Be 1
        $p[0].Tipo | Should -Be 'MSI'
        $p[0].Id | Should -Be $script:pc
        (Get-ItemProperty 'HKLM:\SOFTWARE\OtimizacaoFixture').Instalado | Should -Be 1
    }

    It 'Coleta 1.3.0 (processo separado): seção Programas com MSI, EXE e Appx, sem pacotes do sistema' {
        $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". C:\Otimizacao\src\Coleta.ps1; Get-SecaoPrograma -Elevado `$true | ConvertTo-Json -Depth 3"
        # No 5.1, ConvertFrom-Json devolve o array JSON como um único objeto: ForEach-Object enumera os itens.
        $p = @(($json -join "`n") | ConvertFrom-Json | ForEach-Object { $_ })
        ($p | Where-Object Nome -eq $script:nomeMsi).Tipo | Should -Be 'MSI'
        ($p | Where-Object Nome -eq 'Fixture Otimizacao EXE').Tipo | Should -Be 'EXE'
        $c = $p | Where-Object Id -eq 'Clipchamp.Clipchamp'
        $c.Nome | Should -Be 'Microsoft Clipchamp'
        $c.Provisionado | Should -BeTrue
        $c.TamanhoMB | Should -BeGreaterThan 0
        @($p | Where-Object { $_.Id -in 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.VCLibs.140.00' }).Count | Should -Be 0
        Write-Host "Programas na VM: $(@($p).Count) ($((@($p | Group-Object Tipo | ForEach-Object { "$($_.Name) $($_.Count)" })) -join ', '))"
    }

    It 'Sem lista no perfil: pulado' {
        $s = New-SessaoTeste
        Invoke-A2 -Sessao $s -Perfil (New-PerfilA) -Loja $true
        (Get-Linha $s 'A2').Detalhe | Should -BeLike '*A2Remover*'
    }

    It 'Simulação do MSI: lista o comando e não remove' {
        $s = New-SessaoOtimizacao -Cliente T -Script Aplicativos -Simular
        Invoke-A2 -Sessao $s -Perfil (New-PerfilA -Opcoes @{ A2Remover = @($script:nomeMsi) }) -Loja $true
        $l = Get-Linha $s 'A2'
        $l.Resultado | Should -Be 'Simulado'
        $l.Detalhe | Should -BeLike "msiexec /x $($script:pc) /qn /norestart*"
        Test-ProdutoMsiPresente -ProductCode $script:pc | Should -BeTrue
    }

    It 'MSI: msiexec real remove, só o alvo, e é idempotente' {
        $exeAntes = (Get-ItemProperty "$script:un\OtimizacaoFixtureExe").DisplayName
        $s = New-SessaoTeste
        Invoke-A2 -Sessao $s -Perfil (New-PerfilA -Opcoes @{ A2Remover = @('Fixture Otimizacao M*') }) -Loja $true
        Get-Falha $s | Should -BeNullOrEmpty
        (Get-Linha $s 'A2').Resultado | Should -Be 'OK'
        Test-ProdutoMsiPresente -ProductCode $script:pc | Should -BeFalse
        Test-Path 'HKLM:\SOFTWARE\OtimizacaoFixture' | Should -BeFalse
        (Get-ItemProperty "$script:un\OtimizacaoFixtureExe").DisplayName | Should -Be $exeAntes
        @(Get-ChildItem $s.Pasta -Filter 'msiexec-*.log').Count | Should -Be 1
        $script:sessaoA2 = $s

        $s2 = New-SessaoTeste
        Invoke-A2 -Sessao $s2 -Perfil (New-PerfilA -Opcoes @{ A2Remover = @('Fixture Otimizacao M*') }) -Loja $true
        (Get-Linha $s2 'A2').Resultado | Should -Be 'JaAplicado'
    }

    It 'Reversão do MSI: Pulado sem reinstalar; depois de reinstalado, a conferência dá Revertido' {
        $sr = Invoke-ReversaoTeste -Aplicada $script:sessaoA2
        $l = Get-Linha $sr 'A2'
        $l.Resultado | Should -Be 'Pulado'
        $l.Detalhe | Should -BeLike '*instalador do fabricante (Fixture Otimizacao)*'
        Test-ProdutoMsiPresente -ProductCode $script:pc | Should -BeFalse

        Install-MsiTeste
        $sr2 = Invoke-ReversaoTeste -Aplicada $script:sessaoA2
        (Get-Linha $sr2 'A2').Resultado | Should -Be 'Revertido'
    }

    It 'EXE: achado com o desinstalador e nada removido' {
        $s = New-SessaoTeste
        Invoke-A2 -Sessao $s -Perfil (New-PerfilA -Opcoes @{ A2Remover = @('Fixture Otimizacao EXE') }) -Loja $true 3>$null
        $l = Get-Linha $s 'A2'
        $l.Resultado | Should -Be 'Info'
        $l.Detalhe | Should -BeLike 'ATENÇÃO*C:\Fixture\unins000.exe'
        Test-Path "$script:un\OtimizacaoFixtureExe" | Should -BeTrue
    }

    It 'Ferramenta de driver e programa da Microsoft: pulados sem chamar o msiexec' {
        Mock Invoke-Msiexec { 0 }
        $s = New-SessaoTeste
        Invoke-A2 -Sessao $s -Perfil (New-PerfilA -Opcoes @{ A2Remover = @('Dell Command*', 'Microsoft Edge') }) -Loja $true
        # "Microsoft Edge" casa a entrada do registro e o Appx Microsoft.MicrosoftEdge.Stable: todas puladas.
        $l = @(Get-Linha $s 'A2')
        $l.Count | Should -BeGreaterOrEqual 2
        @($l | Where-Object Resultado -ne 'Pulado').Count | Should -Be 0
        @($l | Where-Object Alvo -like 'Dell Command*').Count | Should -Be 1
        Should -Invoke Invoke-Msiexec -Times 0
        Test-Path "$script:un\OtimizacaoFixtureDell" | Should -BeTrue
    }

    It 'Invoke-Msiexec real com produto inexistente: 1605' {
        # Parênteses: a vírgula tem precedência sobre o +; sem eles o GUID vira três argumentos e o msiexec abre a ajuda e espera.
        Invoke-Msiexec -Argumentos @('/x', ('{' + [guid]::NewGuid().ToString().ToUpper() + '}'), '/qn', '/norestart') | Should -Be 1605
    }

    It 'msiexec <Codigo>: <Esperado>' -ForEach @(
        @{ Codigo = 1605; Esperado = 'JaAplicado' }
        @{ Codigo = 1618; Esperado = 'erro *1618*' }
        @{ Codigo = 1603; Esperado = 'erro *1603*' }
        @{ Codigo = 3010; Esperado = 'OK com reinicialização' }
    ) {
        Set-Content (Join-Path $TestDrive 'codigo.txt') $Codigo
        Mock Invoke-Msiexec { [int](Get-Content (Join-Path $TestDrive 'codigo.txt')) }
        Mock Test-ProdutoMsiPresente { $false }
        $prog = [pscustomobject]@{ Nome = 'Falso'; Versao = '1'; Id = '{00000000-0000-0000-0000-000000000001}'; Fabricante = 'X'; TamanhoMB = 1 }
        $s = New-SessaoTeste
        if ($Esperado -like 'erro*') { { Remove-ProgramaMsi -Sessao $s -Programa $prog } | Should -Throw ($Esperado -replace '^erro ', '') }
        else {
            Remove-ProgramaMsi -Sessao $s -Programa $prog
            $l = Get-Linha $s 'A2'
            $l.Resultado | Should -Be ($Esperado -split ' ')[0]
            if ($Codigo -eq 3010) { $l.Detalhe | Should -BeLike '*Reinicialização*' }
        }
    }

    It 'ProductCode fora do formato {GUID}: recusado sem chamar o msiexec' {
        Mock Invoke-Msiexec { 0 }
        $prog = [pscustomobject]@{ Nome = 'Falso'; Versao = '1'; Id = '{ 1 } /i x'; Fabricante = 'X'; TamanhoMB = 1 }
        { Remove-ProgramaMsi -Sessao (New-SessaoTeste) -Programa $prog } | Should -Throw '*ProductCode*'
        Should -Invoke Invoke-Msiexec -Times 0
    }

    It 'msiexec 0 com produto ainda registrado: erro' {
        Mock Invoke-Msiexec { 0 }
        Mock Test-ProdutoMsiPresente { $true }
        $prog = [pscustomobject]@{ Nome = 'Falso'; Versao = '1'; Id = '{00000000-0000-0000-0000-000000000002}'; Fabricante = 'X'; TamanhoMB = $null }
        { Remove-ProgramaMsi -Sessao (New-SessaoTeste) -Programa $prog } | Should -Throw '*continua registrado*'
    }
}

Describe 'Invoke-Aplicativo' {
    BeforeAll {
        function New-PerfilTeste {
            param([string]$Conteudo)
            $arq = Join-Path $TestDrive ('perfil-{0}.psd1' -f [guid]::NewGuid())
            $Conteudo | Out-File $arq -Encoding UTF8
            $arq
        }
        $script:ordem = Join-Path $TestDrive 'ordem.txt'
    }
    BeforeEach {
        Remove-Item $script:ordem -ErrorAction SilentlyContinue
        Mock Test-PreCondicao { [pscustomobject]@{ Bloqueios = @(); Avisos = @() } }
        Mock Invoke-A1 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'A1' }
        Mock Invoke-A2 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'A2' }
        Mock Invoke-A4 { Add-Content (Join-Path $TestDrive 'ordem.txt') 'A4' }
    }

    It 'Falha no ponto de restauração: nada é executado' {
        Mock New-PontoRestauracao { throw 'Proteção do Sistema desativada' }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('A1','A2','A4') }"
        { Invoke-Aplicativo -Perfil $p } | Should -Throw '*Backup falhou*'
        Test-Path $script:ordem | Should -BeFalse
    }

    It 'Ordem A4, A1, A2 e A3 pulado' {
        Mock New-PontoRestauracao { [pscustomobject]@{ SequenceNumber = 9 } }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('A2','A3','A1','A4') }"
        $s = Invoke-Aplicativo -Perfil $p
        Get-Content $script:ordem | Should -Be @('A4', 'A1', 'A2')
        (Get-Linha $s 'A3').Detalhe | Should -BeLike '*OneDrive não é removido*'
    }

    It 'Só A3: sem ponto de restauração e nada executado' {
        Mock New-PontoRestauracao { throw 'não deveria ser chamado' }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('A3') }"
        Invoke-Aplicativo -Perfil $p 3>$null | Out-Null
        Should -Invoke New-PontoRestauracao -Times 0
        Test-Path $script:ordem | Should -BeFalse
    }

    It 'Simulação não cria ponto de restauração' {
        Mock New-PontoRestauracao { throw 'não deveria ser chamado' }
        $p = New-PerfilTeste "@{ Cliente = 'TesteVM'; Aplicar = @('A1','A4') }"
        Invoke-Aplicativo -Perfil $p -Simular | Out-Null
        Should -Invoke New-PontoRestauracao -Times 0
    }
}
