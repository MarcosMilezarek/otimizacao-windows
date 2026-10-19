BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\Otimizacao.Comum.psm1') -Force
}

Describe 'Get-TipoEquipamento' {
    It 'Notebook pelo chassis <Chassis> sem bateria' -ForEach @(
        @{ Chassis = 9 }, @{ Chassis = 10 }, @{ Chassis = 31 }
    ) {
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_SystemEnclosure' } { [pscustomobject]@{ ChassisTypes = @($Chassis) } }
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Battery' } { }
        Get-TipoEquipamento | Should -Be 'Notebook'
    }

    It 'Desktop pelo chassis 3 sem bateria' {
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_SystemEnclosure' } { [pscustomobject]@{ ChassisTypes = @(3) } }
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Battery' } { }
        Get-TipoEquipamento | Should -Be 'Desktop'
    }

    It 'Notebook quando há bateria, mesmo com chassis de desktop' {
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_SystemEnclosure' } { [pscustomobject]@{ ChassisTypes = @(3) } }
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Battery' } { [pscustomobject]@{ BatteryStatus = 2 } }
        Get-TipoEquipamento | Should -Be 'Notebook'
    }
}

Describe 'Get-UsuarioAlvo' {
    It 'Falha com mensagem clara quando não há usuário no console e nenhum SID foi informado' {
        Mock -ModuleName Otimizacao.Comum Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' } { [pscustomobject]@{ UserName = $null } }
        { Get-UsuarioAlvo } | Should -Throw '*Nenhum usuário conectado*'
    }

    It 'Falha quando o SID não tem perfil' {
        { Get-UsuarioAlvo -Sid 'S-1-5-21-0-0-0-99999' } | Should -Throw '*Perfil não encontrado*'
    }

    It 'Resolve o usuário atual pelo SID e retorna o perfil' {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $r = Get-UsuarioAlvo -Sid $sid
        $r.Sid | Should -Be $sid
        $r.Perfil | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-NoHiveUsuario' {
    It 'Usa o hive já carregado sem chamar reg.exe' {
        Mock -ModuleName Otimizacao.Comum reg.exe { throw 'não deveria carregar' }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $raiz = Invoke-NoHiveUsuario -Sid $sid -Perfil 'C:\inexistente' -ScriptBlock { param($r) $r }
        $raiz | Should -Be "Registry::HKEY_USERS\$sid"
        Should -Invoke -ModuleName Otimizacao.Comum reg.exe -Times 0
    }

    It 'Recusa carregar hive sem administrador' {
        Mock -ModuleName Otimizacao.Comum Test-Administrador { $false }
        { Invoke-NoHiveUsuario -Sid 'S-1-5-21-0-0-0-99999' -Perfil 'C:\inexistente' -ScriptBlock { } } | Should -Throw '*exige administrador*'
    }

    It 'Descarrega o hive mesmo se o bloco falhar' {
        Mock -ModuleName Otimizacao.Comum Test-Administrador { $true }
        Mock -ModuleName Otimizacao.Comum reg.exe { $global:LASTEXITCODE = 0 }
        { Invoke-NoHiveUsuario -Sid 'S-1-5-21-0-0-0-99999' -Perfil 'C:\x' -ScriptBlock { throw 'falha no bloco' } } | Should -Throw '*falha no bloco*'
        Should -Invoke -ModuleName Otimizacao.Comum reg.exe -Times 1 -ParameterFilter { $args[0] -eq 'unload' }
    }

    It 'Informa falha ao carregar o NTUSER.DAT' {
        Mock -ModuleName Otimizacao.Comum Test-Administrador { $true }
        Mock -ModuleName Otimizacao.Comum reg.exe { $global:LASTEXITCODE = 1 }
        { Invoke-NoHiveUsuario -Sid 'S-1-5-21-0-0-0-99999' -Perfil 'C:\x' -ScriptBlock { } } | Should -Throw '*Falha ao carregar*'
    }
}

Describe 'Test-ReinicializacaoPendente' {
    It 'Retorna os três indicadores como booleanos' {
        $r = Test-ReinicializacaoPendente
        $r.ComponentBasedServicing | Should -BeOfType [bool]
        $r.WindowsUpdate | Should -BeOfType [bool]
        $r.RenomeacaoArquivos | Should -BeOfType [bool]
    }
}

Describe 'Test-GerenciadoMdm' {
    It 'Consulta a API sem erro e retorna booleano (inscrições internas do Windows não contam)' {
        Test-GerenciadoMdm | Should -BeOfType [bool]
        if ($env:OTIMIZACAO_VM -eq '1') { Test-GerenciadoMdm | Should -BeFalse -Because 'a VM de teste não tem MDM' }
    }
}

Describe 'Invoke-ReversaoPendente' {
    BeforeEach {
        $script:raiz = Join-Path $TestDrive ([guid]::NewGuid())
        $script:base = Join-Path $script:raiz 'C'
        foreach ($n in '20260101-000000-X', '20260102-000000-X', '20260103-000000-X') {
            New-Item -ItemType Directory (Join-Path $script:base $n) -Force | Out-Null
        }
        # 1ª e 3ª sessões alteraram algo; a 2ª (reaplicação) não tem estado-original.json.
        '[{"Tipo":"Falso","Item":"A"}]' | Out-File (Join-Path $script:base '20260101-000000-X\estado-original.json') -Encoding UTF8
        '[{"Tipo":"Falso","Item":"C"}]' | Out-File (Join-Path $script:base '20260103-000000-X\estado-original.json') -Encoding UTF8
        $script:ordem = New-Object System.Collections.Generic.List[string]
        $script:manip = @{ Falso = { param($e) $script:ordem.Add($e.Item) } }
    }

    It 'Sem Pasta: reverte todas as pendentes, da mais recente para a mais antiga, e ignora a sessão da própria reversão' {
        $s = New-SessaoOtimizacao -Cliente C -Script 'X-Reversao' -Raiz $script:raiz
        Invoke-ReversaoPendente -Sessao $s -Cliente C -Script X -Manipuladores $script:manip -Raiz $script:raiz
        ($script:ordem -join ',') | Should -Be 'C,A'
        foreach ($n in '20260101-000000-X', '20260102-000000-X', '20260103-000000-X') {
            Test-Path (Join-Path $script:base "$n\revertido.txt") | Should -BeTrue
        }
        Test-Path (Join-Path $s.Pasta 'revertido.txt') | Should -BeFalse
        { Invoke-ReversaoPendente -Sessao $s -Cliente C -Script X -Manipuladores $script:manip -Raiz $script:raiz } | Should -Throw '*Nenhuma sessão*'
    }

    It 'Com Pasta: reverte só a sessão indicada' {
        $s = New-SessaoOtimizacao -Cliente C -Script 'X-Reversao' -Raiz $script:raiz
        Invoke-ReversaoPendente -Sessao $s -Cliente C -Script X -Pasta (Join-Path $script:base '20260101-000000-X') -Manipuladores $script:manip -Raiz $script:raiz
        ($script:ordem -join ',') | Should -Be 'A'
        Test-Path (Join-Path $script:base '20260103-000000-X\revertido.txt') | Should -BeFalse
    }

    It 'Falha numa sessão interrompe antes das mais antigas' {
        $manip = @{ Falso = { param($e) if ($e.Item -eq 'C') { throw 'falha simulada' }; $script:ordem.Add($e.Item) } }
        $s = New-SessaoOtimizacao -Cliente C -Script 'X-Reversao' -Raiz $script:raiz
        Invoke-ReversaoPendente -Sessao $s -Cliente C -Script X -Manipuladores $manip -Raiz $script:raiz
        $script:ordem.Count | Should -Be 0
        Test-Path (Join-Path $script:base '20260103-000000-X\revertido.txt') | Should -BeFalse
        ($s.Linhas | Where-Object { $_.Item -eq 'Reversao' -and $_.Resultado -eq 'Falha' }).Detalhe | Should -BeLike '*interrompida*'
    }

    It 'Simulação não marca nenhuma sessão como revertida' {
        $s = New-SessaoOtimizacao -Cliente C -Script 'X-Reversao' -Simular
        $manip = @{ Falso = { param($e) } }
        Invoke-ReversaoPendente -Sessao $s -Cliente C -Script X -Manipuladores $manip -Raiz $script:raiz
        @(Get-ChildItem $script:base -Recurse -Filter revertido.txt).Count | Should -Be 0
    }
}

Describe 'Test-PreCondicao: instalação do Windows em andamento' {
    BeforeEach {
        Mock -ModuleName Otimizacao.Comum Get-Process -ParameterFilter { $Name -contains 'SetupHost' } { }
        Mock -ModuleName Otimizacao.Comum Get-Process -ParameterFilter { $Name -contains 'TiWorker' } { [pscustomobject]@{ Name = 'TiWorker' } }
        # Outras chamadas de New-Object (listas) vão para o cmdlet real.
        Mock -ModuleName Otimizacao.Comum New-Object { & (Get-Command New-Object -CommandType Cmdlet) @PesterBoundParameters }
    }

    It 'TiWorker sem instalação pelo Windows Update: só aviso' {
        Mock -ModuleName Otimizacao.Comum New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Installer' } { [pscustomobject]@{ IsBusy = $false } }
        $r = Test-PreCondicao -PermitirReinicializacaoPendente
        @($r.Bloqueios | Where-Object { $_ -match 'TiWorker|Windows Update|SetupHost' }) | Should -HaveCount 0
        @($r.Avisos | Where-Object { $_ -match 'TiWorker' }) | Should -HaveCount 1
    }

    It 'IsBusy verdadeiro: bloqueia' {
        Mock -ModuleName Otimizacao.Comum New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Installer' } { [pscustomobject]@{ IsBusy = $true } }
        $r = Test-PreCondicao -PermitirReinicializacaoPendente
        @($r.Bloqueios | Where-Object { $_ -match 'Windows Update' }) | Should -HaveCount 1
    }

    It 'API indisponível com TiWorker ativo: bloqueia (lado conservador)' {
        Mock -ModuleName Otimizacao.Comum New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Installer' } { throw 'COM indisponível' }
        $r = Test-PreCondicao -PermitirReinicializacaoPendente
        @($r.Bloqueios | Where-Object { $_ -match 'TiWorker' }) | Should -HaveCount 1
    }

    It 'SetupHost ativo: bloqueia' {
        Mock -ModuleName Otimizacao.Comum Get-Process -ParameterFilter { $Name -contains 'SetupHost' } { [pscustomobject]@{ Name = 'SetupHost' } }
        Mock -ModuleName Otimizacao.Comum New-Object -ParameterFilter { $ComObject -eq 'Microsoft.Update.Installer' } { [pscustomobject]@{ IsBusy = $false } }
        $r = Test-PreCondicao -PermitirReinicializacaoPendente
        @($r.Bloqueios | Where-Object { $_ -match 'SetupHost' }) | Should -HaveCount 1
    }
}

Describe 'Programas instalados (leitura)' {
    It 'Entrada Uninstall: <Caso>' -ForEach @(
        @{ Caso = 'MSI com ProductCode'; Chave = '{11111111-2222-3333-4444-555555555555}'; Valores = @{ DisplayName = 'Prog'; WindowsInstaller = 1; EstimatedSize = 2048; Publisher = 'Fab'; DisplayVersion = '1.0' }; Tipo = 'MSI' }
        @{ Caso = 'EXE'; Chave = 'Prog_is1'; Valores = @{ DisplayName = 'Prog'; UninstallString = 'C:\p\unins000.exe' }; Tipo = 'EXE' }
        @{ Caso = 'WindowsInstaller sem chave GUID vira EXE'; Chave = 'Prog'; Valores = @{ DisplayName = 'Prog'; WindowsInstaller = 1 }; Tipo = 'EXE' }
        @{ Caso = 'sem DisplayName é ignorada'; Chave = 'AddressBook'; Valores = @{}; Tipo = $null }
        @{ Caso = 'SystemComponent é ignorada'; Chave = 'X'; Valores = @{ DisplayName = 'X'; SystemComponent = 1 }; Tipo = $null }
        @{ Caso = 'atualização (ParentKeyName) é ignorada'; Chave = 'KB1'; Valores = @{ DisplayName = 'Update'; ParentKeyName = 'Office' }; Tipo = $null }
        @{ Caso = 'ReleaseType Hotfix é ignorada'; Chave = 'KB2'; Valores = @{ DisplayName = 'Hotfix'; ReleaseType = 'Hotfix' }; Tipo = $null }
    ) {
        $r = ConvertFrom-EntradaUninstall -Chave $Chave -Valores $Valores -Escopo 'Maquina'
        if ($Tipo) {
            $r.Tipo | Should -Be $Tipo
            $r.Id | Should -Be $Chave
            if ($Valores.ContainsKey('EstimatedSize')) { $r.TamanhoMB | Should -Be 2 } else { $r.TamanhoMB | Should -BeNullOrEmpty }
        }
        else { $r | Should -BeNullOrEmpty }
    }

    It 'Texto do manifesto: literal volta igual; ms-resource sem pacote volta nulo' {
        Resolve-TextoPacote -Texto 'Microsoft Store' -Nome 'a' -NomeCompleto 'a_1_x64__b' | Should -Be 'Microsoft Store'
        Resolve-TextoPacote -Texto 'ms-resource:AppName' -Nome 'Pacote.Inexistente' -NomeCompleto 'Pacote.Inexistente_1.0.0.0_x64__abc' | Should -BeNullOrEmpty
    }

    It 'Nome de exibição do manifesto; sem manifesto, nome do pacote' {
        $xml = '<?xml version="1.0" encoding="utf-8"?><Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Properties>' +
        '<DisplayName>Calculadora Teste</DisplayName><PublisherDisplayName>Fab Teste</PublisherDisplayName></Properties></Package>'
        $xml | Out-File (Join-Path $TestDrive 'AppxManifest.xml') -Encoding UTF8
        $r = Get-NomeExibicaoAppx -Pacote ([pscustomobject]@{ Name = 'Teste.Calc'; PackageFullName = 'Teste.Calc_1_x64__abc'; InstallLocation = $TestDrive })
        $r.Nome | Should -Be 'Calculadora Teste'
        $r.Fabricante | Should -Be 'Fab Teste'
        (Get-NomeExibicaoAppx -Pacote ([pscustomobject]@{ Name = 'Sem.Manifesto'; PackageFullName = 'x'; InstallLocation = (Join-Path $TestDrive 'nada') })).Nome | Should -Be 'Sem.Manifesto'
    }
}
