# Perfil.ps1: geração do perfil do cliente pelo Menu. Roda no host: consultas ao sistema são simuladas por Mock e os
# arquivos ficam em TestDrive.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Perfil.ps1')
}

Describe 'Get-CatalogoPerfil' {
    BeforeAll { $script:Cat = @(Get-CatalogoPerfil) }

    It 'Tem os 40 itens na ordem de execução dos scripts' {
        $esperado = @('M1', 'M2', 'M3', 'M4', 'M8', 'A1', 'A2', 'A3', 'A4') + @(1..12 | ForEach-Object { "I$_" }) +
            @(1..10 | ForEach-Object { "V$_" }) + @(1..9 | ForEach-Object { "L$_" })
        ($script:Cat | ForEach-Object { $_.Id }) -join ',' | Should -Be ($esperado -join ',')
    }

    It 'Todo item tem texto e perda' {
        @($script:Cat | Where-Object { -not $_.Texto -or -not $_.Perda }).Count | Should -Be 0
    }

    It 'Itens de lista apontam para a chave de Opcoes do script' {
        $mapa = @{}
        $script:Cat | Where-Object { $_.Opcao } | ForEach-Object { $mapa[$_.Id] = $_.Opcao }
        $mapa.Count | Should -Be 5
        $mapa['I1'] | Should -Be 'I1Desabilitar'
        $mapa['I4'] | Should -Be 'I4NegarSegundoPlano'
        $mapa['I9'] | Should -Be 'I9Tarefas'
        $mapa['I10'] | Should -Be 'I10Servicos'
        $mapa['A2'] | Should -Be 'A2Remover'
    }

    It 'Só o A3 é informativo' {
        @($script:Cat | Where-Object { $_.Informativo } | ForEach-Object { $_.Id }) -join ',' | Should -Be 'A3'
    }

    It 'L4 a L7 e A1 trazem aviso de aprovação' {
        foreach ($id in 'L4', 'L5', 'L6', 'L7', 'A1') { ($script:Cat | Where-Object Id -EQ $id).Aviso | Should -Not -BeNullOrEmpty }
    }
}

Describe 'ConvertFrom-Selecao' {
    It 'Aceita IDs sem diferenciar maiúsculas, números, vírgulas e faixas' {
        (ConvertFrom-Selecao -Texto 'l1, 3 5-6' -Validos 'L1', 'L2', 'L3', 'L4', 'L5', 'L6') -join ',' | Should -Be 'L1,L3,L5,L6'
    }

    It 'Devolve na ordem dos válidos e sem repetição' {
        (ConvertFrom-Selecao -Texto 'L3 1 l3' -Validos 'L1', 'L2', 'L3') -join ',' | Should -Be 'L1,L3'
    }

    It 'Número fora da faixa lança ArgumentException com o token' {
        { ConvertFrom-Selecao -Texto '7' -Validos 'L1', 'L2' } | Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage "*'7'*"
    }

    It 'ID desconhecido lança' {
        { ConvertFrom-Selecao -Texto 'X9' -Validos 'L1' } | Should -Throw -ExceptionType ([ArgumentException])
    }

    It 'Texto vazio devolve lista vazia' {
        @(ConvertFrom-Selecao -Texto '' -Validos 'L1').Count | Should -Be 0
    }
}

Describe 'Listas da máquina' {
    BeforeAll { $script:Alvo = [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Perfil = 'C:\Users\cliente' } }

    It 'I1 mostra só entradas que não são componentes do Windows' {
        Mock Invoke-NoHiveUsuario { & $ScriptBlock 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001' }
        Mock Get-FonteInicializacao {
            if ($Escopo -eq 'Maquina') {
                [pscustomobject]@{ Origem = 'Maquina\Run'; Nome = 'SecurityHealth'; Comando = "$env:windir\System32\SecurityHealthSystray.exe" }
                [pscustomobject]@{ Origem = 'Maquina\Run'; Nome = 'X Agent'; Comando = '"C:\Program Files\X\x.exe" /min' }
            }
            else { [pscustomobject]@{ Origem = 'Usuario\Run'; Nome = 'X Agent'; Comando = '"C:\Program Files\X\x.exe" /min' } }
        }
        $r = @(Get-CandidatoI1 -Alvo $script:Alvo)
        ($r | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'X Agent'
        Should -Invoke Invoke-NoHiveUsuario -Times 1 -Exactly -ParameterFilter { $Sid -eq 'S-1-5-21-1-2-3-1001' -and $Perfil -eq 'C:\Users\cliente' }
    }

    It 'I4 descarta frameworks, pacotes do sistema e PFN inválido' {
        Mock Get-AppxPackage {
            [pscustomobject]@{ Name = 'Spotify'; PackageFamilyName = 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
            [pscustomobject]@{ Name = 'Fw'; PackageFamilyName = 'Microsoft.VCLibs_8wekyb3d8bbwe'; IsFramework = $true; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
            [pscustomobject]@{ Name = 'Sis'; PackageFamilyName = 'Microsoft.Windows.ShellExperienceHost_cw5n1h2txyewy'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $true; SignatureKind = 'System' }
            [pscustomobject]@{ Name = 'Ruim'; PackageFamilyName = 'nome invalido'; IsFramework = $false; IsResourcePackage = $false; NonRemovable = $false; SignatureKind = 'Store' }
        }
        Mock Get-NomeExibicaoAppx { [pscustomobject]@{ Nome = "App $($Pacote.Name)"; Fabricante = 'X' } }
        $r = @(Get-CandidatoI4 -Alvo $script:Alvo)
        ($r | ForEach-Object { $_.Pfn }) -join '|' | Should -Be 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0'
        $r[0].Nome | Should -Be 'App Spotify'
        Should -Invoke Get-AppxPackage -ParameterFilter { $User -eq 'S-1-5-21-1-2-3-1001' }
    }

    It 'I9 mostra só tarefas fora de \Microsoft\ e não desabilitadas' {
        Mock Get-ScheduledTask {
            $acao = @([pscustomobject]@{ Execute = 'C:\Program Files\F\upd.exe' })
            [pscustomobject]@{ TaskPath = '\Microsoft\Windows\'; TaskName = 'A'; State = 'Ready'; Actions = $acao }
            [pscustomobject]@{ TaskPath = '\Fabricante\'; TaskName = 'Atualizar'; State = 'Ready'; Actions = $acao }
            [pscustomobject]@{ TaskPath = '\Outra\'; TaskName = 'B'; State = 'Disabled'; Actions = $acao }
        }
        Mock Get-EmpresaExecutavel { 'F SA' }
        (@(Get-CandidatoI9) | ForEach-Object { $_.Caminho }) -join '|' | Should -Be '\Fabricante\Atualizar'
    }

    It 'I10 mostra só serviços de terceiros com início automático ou manual' {
        Mock Get-Service {
            'Win', 'Drv', 'Boot', 'Terceiro', 'Desativado' | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = "Serviço $_" } }
        }
        Mock Get-InicioServico {
            switch ($Nome) {
                'Win' { [pscustomobject]@{ Start = 2; Atrasado = $false; Tipo = 0x10; ImagePath = '%SystemRoot%\System32\svchost.exe -k netsvcs' } }
                'Drv' { [pscustomobject]@{ Start = 3; Atrasado = $false; Tipo = 0x1; ImagePath = 'C:\Program Files\D\d.sys' } }
                'Boot' { [pscustomobject]@{ Start = 1; Atrasado = $false; Tipo = 0x10; ImagePath = 'C:\Program Files\B\b.exe' } }
                'Terceiro' { [pscustomobject]@{ Start = 2; Atrasado = $false; Tipo = 0x10; ImagePath = '"C:\Program Files\T\t.exe"' } }
                'Desativado' { [pscustomobject]@{ Start = 4; Atrasado = $false; Tipo = 0x10; ImagePath = 'C:\Program Files\Z\z.exe' } }
            }
        }
        $r = @(Get-CandidatoI10)
        ($r | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'Terceiro'
        $r[0].Exibicao | Should -Be 'Serviço Terceiro'
    }

    It 'I10 esconde serviços da Microsoft fora de %windir% (Defender é intocável)' {
        Mock Get-Service { 'WinDefend', 'Terceiro' | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = $_ } } }
        Mock Get-InicioServico {
            $img = if ($Nome -eq 'WinDefend') { '"C:\ProgramData\Microsoft\Windows Defender\platform\4.18\MsMpEng.exe"' } else { 'C:\Program Files\T\t.exe' }
            [pscustomobject]@{ Start = 2; Atrasado = $false; Tipo = 0x10; ImagePath = $img }
        }
        Mock Get-EmpresaExecutavel { if ($Caminho -like '*MsMpEng.exe') { 'Microsoft Corporation' } else { 'T Ltda' } }
        (@(Get-CandidatoI10) | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'Terceiro'
    }

    It 'I9 esconde tarefas que executam programa do Windows ou da Microsoft' {
        Mock Get-ScheduledTask {
            [pscustomobject]@{ TaskPath = '\'; TaskName = 'CreateExplorerShellUnelevatedTask'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'C:\Windows\explorer.exe' }) }
            [pscustomobject]@{ TaskPath = '\'; TaskName = 'MicrosoftEdgeUpdateTaskMachineCore'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'C:\Program Files (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe' }) }
            [pscustomobject]@{ TaskPath = '\Fabricante\'; TaskName = 'Atualizar'; State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'C:\Program Files\F\upd.exe' }) }
            [pscustomobject]@{ TaskPath = '\SoftLanding\'; TaskName = 'Com'; State = 'Ready'; Actions = @([pscustomobject]@{ ClassId = '{00000000-0000-0000-0000-000000000000}' }) }
        }
        Mock Get-EmpresaExecutavel { if ($Caminho -like '*EdgeUpdate*') { 'Microsoft Corporation' } else { 'F SA' } }
        (@(Get-CandidatoI9) | ForEach-Object { $_.Caminho }) -join '|' | Should -Be '\Fabricante\Atualizar'
    }

    It 'A2 esconde ferramentas de driver e programas da Microsoft' {
        Mock Get-ProgramaMaquina {
            [pscustomobject]@{ Nome = 'Dell SupportAssist'; Fabricante = 'Dell Inc.'; Versao = '4'; Tipo = 'MSI'; Id = '{11111111-1111-1111-1111-111111111111}' }
            [pscustomobject]@{ Nome = 'Microsoft Visual C++'; Fabricante = 'Microsoft Corporation'; Versao = '14'; Tipo = 'MSI'; Id = '{22222222-2222-2222-2222-222222222222}' }
            [pscustomobject]@{ Nome = 'HP Smart'; Fabricante = 'HP Inc.'; Versao = '1'; Tipo = 'Appx'; Id = 'AD2F1837.HPPrinterControl' }
        }
        (@(Get-CandidatoA2) | ForEach-Object { $_.Nome }) -join '|' | Should -Be 'HP Smart'
    }
}

Describe 'Save-PerfilGerado' {
    BeforeEach {
        $script:Pasta = Join-Path $TestDrive ([guid]::NewGuid())
        $script:Dados = @{
            Cliente = 'Teste'; UsuarioSid = ''
            Aplicar = @('M8', 'I1', 'I10', 'A2')
            Opcoes  = @{ I1Desabilitar = @("O'Brien Tool"); I10Servicos = @{ 'Svc X' = 'Disabled' }; A2Remover = @('HP*'); M8Inicio = 7; M8Fim = 19 }
        }
    }

    It 'Grava e relê os mesmos valores, inclusive com apóstrofo' {
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta
        $arq | Should -Be (Join-Path $script:Pasta 'Teste.psd1')
        $p = Import-PerfilCliente -Caminho $arq
        $p.Cliente | Should -Be 'Teste'
        $p.UsuarioSid | Should -Be ''
        $p.Aplicar -join ',' | Should -Be 'M8,I1,I10,A2'
        @($p.Pular).Count | Should -Be 0
        @($p.Opcoes.I1Desabilitar) -join '|' | Should -Be "O'Brien Tool"
        $p.Opcoes.I10Servicos['Svc X'] | Should -Be 'Disabled'
        @($p.Opcoes.A2Remover) -join '|' | Should -Be 'HP*'
        $p.Opcoes.M8Inicio | Should -Be 7
        $p.Opcoes.M8Fim | Should -Be 19
        foreach ($c in 'Inicializacao', 'Servicos', 'Tarefas', 'Aplicativos') { $p.Protegidos.ContainsKey($c) | Should -BeTrue }
    }

    It 'Grava em UTF-8 com BOM' {
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta
        $b = [IO.File]::ReadAllBytes($arq)
        '{0:X2}{1:X2}{2:X2}' -f $b[0], $b[1], $b[2] | Should -Be 'EFBBBF'
    }

    It 'Não sobrescreve sem -Force' {
        Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta | Out-Null
        { Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta } | Should -Throw
        $script:Dados.Aplicar = @('L1')
        $arq = Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta -Force
        (Import-PerfilCliente -Caminho $arq).Aplicar -join ',' | Should -Be 'L1'
    }

    It 'Cliente inválido lança e não deixa arquivo' {
        $script:Dados.Cliente = 'a b'
        { Save-PerfilGerado -Dados $script:Dados -Pasta $script:Pasta } | Should -Throw
        @(Get-ChildItem -LiteralPath $script:Pasta -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
