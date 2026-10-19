# Verificacao.ps1 é somente leitura: estes testes rodam no host e na VM. Registro, pacotes, tarefas e serviços por Mock.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Verificacao.ps1') -Perfil 'nao-usado.psd1'
    $script:Fonte = Join-Path $PSScriptRoot '..\src\Verificacao.ps1'
    $script:RaizUsuario = 'Registry::HKEY_USERS\Otimizacao_T'
    $script:Alvo = [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Perfil = 'C:\Users\t' }

    function New-PerfilTeste {
        param([string[]]$Aplicar = @(), [hashtable]$Opcoes = @{}, [hashtable]$Protegidos = @{ Inicializacao = @(); Servicos = @(); Tarefas = @(); Aplicativos = @() })
        [pscustomobject]@{ Cliente = 'T'; UsuarioSid = $script:Alvo.Sid; Aplicar = $Aplicar; Pular = @(); Protegidos = $Protegidos; Opcoes = $Opcoes }
    }
    function New-SessaoTeste { New-SessaoOtimizacao -Cliente T -Script Teste -Simular }
    # Registro falso: Set-ValorRegistro (scripts) grava aqui e Get-ValorRegistro (scripts e verificação) lê daqui.
    function Set-RegistroFalso { param([string]$Caminho, [string]$Nome, $Valor) $script:Reg["$Caminho|$Nome".ToLower()] = $Valor }
    function Get-Item1 { param($R, [string]$Item) @($R | Where-Object Item -eq $Item) }
}

Describe 'Somente leitura (análise estática do código)' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Fonte, [ref]$null, [ref]$null)
        $script:Comandos = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))
        $script:Nomes = @($script:Comandos | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
    }

    It 'Não chama cmdlet nem função que altere o sistema' {
        $verbos = '^(Set|New|Remove|Disable|Enable|Start|Stop|Restart|Register|Unregister|Install|Uninstall|Clear|Add|Optimize|Repair|Checkpoint|Update|Copy|Move|Rename|Reset|Mount|Dismount|Initialize|Grant|Revoke|Suspend|Resume|Export|Out)-'
        $permitidos = 'New-Verificado', 'New-Pendente', 'New-Object', 'Add-Member'
        @($script:Nomes | Where-Object { $_ -match $verbos -and $permitidos -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'Não chama executáveis que alteram o sistema' {
        $exes = 'fsutil', 'powercfg', 'reg', 'msiexec', 'cleanmgr', 'dism', 'sfc', 'shutdown', 'icacls', 'schtasks', 'sc', 'bcdedit', 'defrag', 'chkdsk'
        @($script:Nomes | Where-Object { $exes -contains ($_ -replace '\.exe$', '') }) | Should -BeNullOrEmpty
    }

    It 'Invoke-* usados são só leitura: Invoke-CimMethod apenas com DefragAnalysis e Invoke-NoHiveUsuario (exceção declarada)' {
        @($script:Nomes | Where-Object { $_ -like 'Invoke-*' -and $_ -notin 'Invoke-CimMethod', 'Invoke-NoHiveUsuario', 'Invoke-Checagem', 'Invoke-Verificacao' }) | Should -BeNullOrEmpty
        $cim = @($script:Comandos | Where-Object { $_.GetCommandName() -eq 'Invoke-CimMethod' })
        $cim.Count | Should -Be 1
        $cim[0].Extent.Text | Should -Match '-MethodName DefragAnalysis'
    }

    It 'Grava arquivo só em -Relatorio' {
        $texto = [IO.File]::ReadAllText($script:Fonte)
        ([regex]::Matches($texto, '\[IO\.File\]::Write')).Count | Should -Be 1
        $texto | Should -Match '\[IO\.File\]::WriteAllLines\(\$Relatorio'
    }

    It 'Não usa travessão' {
        [IO.File]::ReadAllText($script:Fonte, [Text.Encoding]::UTF8) | Should -Not -Match '[\u2013\u2014]'
    }
}

Describe 'Ida e volta: o que cada script grava é reconhecido como Alterado' {
    It 'Leituras do usuário são pares (SubChave, Nome), não lista plana' {
        @($script:LeiturasUsuario).Count | Should -Be 11
        @($script:LeiturasUsuario | Where-Object { $_ -isnot [array] -or $_.Count -ne 2 }) | Should -BeNullOrEmpty
    }

    BeforeEach {
        $script:Reg = @{}
        Mock Set-ValorRegistro { $script:Reg["$Raiz\$SubChave|$Nome".ToLower()] = $Valor }
        Mock Get-ValorRegistro {
            $k = "$Caminho|$Nome".ToLower()
            if ($script:Reg.ContainsKey($k)) { [pscustomobject]@{ ChaveExiste = $true; Existe = $true; Valor = $script:Reg[$k]; Tipo = 'DWord' } }
            else { [pscustomobject]@{ ChaveExiste = $false; Existe = $false; Valor = $null; Tipo = $null } }
        }
        Mock Invoke-NoHiveUsuario { & $ScriptBlock $script:RaizUsuario }
        $script:DadoUsuario = $null
        $script:MotivoUsuario = 'teste'
    }

    It 'L9 Sensor de Armazenamento' {
        Invoke-L9 -Sessao (New-SessaoTeste)
        $r = @(Test-ItemLimpeza -Id L9)
        $r.Alterado | Should -Be $true
    }

    It 'I2, I3, I5, I8, I11 (Enterprise) e I12' {
        Mock Test-AppInstalado { $true }
        Mock Get-EstadoRecall { 'Enabled' }
        Mock Test-UcpdAtivo { $false }
        $info = [pscustomobject]@{ Build = 26200; UBR = 5000; EditionId = 'Enterprise' }
        $s = New-SessaoTeste
        Invoke-I2 -Sessao $s; Invoke-I3 -Sessao $s; Invoke-I5 -Sessao $s -Info $info; Invoke-I8 -Sessao $s
        Invoke-I11Maquina -Sessao $s -Info $info; Invoke-I12 -Sessao $s -Info $info
        Set-RegistroFalso "$($script:RaizUsuario)\Software\Policies\Microsoft\Windows\CloudContent" 'DisableThirdPartySuggestions' 1
        $script:DadoUsuario = Get-DadoUsuario -Alvo $script:Alvo
        $p = New-PerfilTeste
        foreach ($id in 'I2', 'I3', 'I5', 'I8', 'I11', 'I12') {
            $r = @(Test-ItemInicializacao -Id $id -Perfil $p -Info $info)
            $r.Alterado | Should -Be $true -Because "$id deveria ser reconhecido ($($r.Texto))"
        }
    }

    It 'I4 lista de apps negados' {
        $p = New-PerfilTeste -Opcoes @{ I4NegarSegundoPlano = @('Contoso.App_8wekyb3d8bbwe', 'Fabrikam.App_8wekyb3d8bbwe') }
        Invoke-I4 -Sessao (New-SessaoTeste) -Perfil $p
        (@(Test-ItemInicializacao -Id I4 -Perfil $p -Info $null)).Alterado | Should -Be $true
    }

    It 'M8 horário ativo e M4 TRIM' {
        $p = New-PerfilTeste -Opcoes @{ M8Inicio = 7; M8Fim = 19 }
        $info = [pscustomobject]@{ EditionId = 'Professional' }
        Invoke-M8 -Sessao (New-SessaoTeste) -Perfil $p -Info $info
        (@(Test-ItemManutencao -Id M8 -Perfil $p -Info $info)).Alterado | Should -Be $true

        Mock Test-TemSsd { $true }
        Mock Invoke-Fsutil { Set-RegistroFalso "Registry::HKEY_LOCAL_MACHINE\$($script:SubChaveFs)" 'DisableDeleteNotification' 0 }
        Set-RegistroFalso "Registry::HKEY_LOCAL_MACHINE\$($script:SubChaveFs)" 'DisableDeleteNotification' 1
        (@(Test-ItemManutencao -Id M4 -Perfil $p -Info $info)).Alterado | Should -Be $false
        $s = New-SessaoOtimizacao -Cliente T -Script Teste -Raiz $TestDrive
        Invoke-M4 -Sessao $s
        (@(Test-ItemManutencao -Id M4 -Perfil $p -Info $info)).Alterado | Should -Be $true
    }

    It 'V5 e V7 da tela de entrada' {
        $s = New-SessaoTeste
        Invoke-V5 -Sessao $s -Desligar $true
        Invoke-V7Maquina -Sessao $s
        $p = New-PerfilTeste -Opcoes @{ V5DesligarInicializacaoRapida = $true }
        (@(Test-ItemVisualEnergia -Id V5 -Perfil $p -Info $null)).Alterado | Should -Be $true
        $r = @(Test-ItemVisualEnergia -Id V7 -Perfil $p -Info $null)
        (Get-Item1 $r V7 | Where-Object Alterado).Texto | Should -Match 'tela de entrada'
    }

    It 'V1, V2, V7, V8, V9 e V10 no usuário alvo (hive carregado pelo script)' {
        Set-RegistroFalso "$($script:RaizUsuario)\Control Panel\Desktop" 'UserPreferencesMask' ([byte[]](0x9E, 0x3E, 0x07, 0x80, 0x12, 0, 0, 0))
        $info = [pscustomobject]@{ Build = 26100 }
        Invoke-ItemUsuario -Sessao (New-SessaoTeste) -Alvo $script:Alvo -Itens @('V1', 'V2', 'V7', 'V8', 'V9', 'V10') -Info $info
        Invoke-V7Maquina -Sessao (New-SessaoTeste)
        $script:DadoUsuario = Get-DadoUsuario -Alvo $script:Alvo
        foreach ($id in 'V1', 'V2', 'V7', 'V8', 'V9', 'V10') {
            $r = @(Test-ItemVisualEnergia -Id $id -Perfil (New-PerfilTeste) -Info $info)
            $r.Count | Should -Be 1 -Because "${id}: $($r.Texto -join ' | ')"
            $r[0].Alterado | Should -Be $true -Because "$id deveria ser reconhecido ($($r[0].Texto))"
        }
    }

    It 'Sem nada gravado: itens de registro vão para o bloco 2 como não aplicados' {
        $script:DadoUsuario = Get-DadoUsuario -Alvo $script:Alvo
        $r = @(Test-ItemLimpeza -Id L9) + @(Test-ItemVisualEnergia -Id V2 -Perfil (New-PerfilTeste) -Info $null)
        $r | ForEach-Object { $_.Alterado | Should -Be $false; $_.Texto | Should -Match 'não aplicado' }
    }

    It 'Política já definida com outro valor: motivo de política, não de falha' {
        Set-RegistroFalso 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 1
        $r = @(Test-ItemInicializacao -Id I8 -Perfil (New-PerfilTeste) -Info $null)
        $r.Alterado | Should -Be $false
        $r.Texto | Should -Match 'já existe política com outro valor, definida pela empresa, MDM ou outra ferramenta \(AllowGameDVR = 1\)\.$'
    }
}

Describe 'Ida e volta: I7 e I11 do usuário (Inicializacao)' {
    BeforeAll {
        # Invoke-ItemUsuario de Inicializacao (no escopo geral vale o de VisualEnergia, carregado depois).
        . (Join-Path $PSScriptRoot '..\src\Inicializacao.ps1') -Perfil 'nao-usado.psd1'
    }
    BeforeEach {
        $script:Reg = @{}
        Mock Set-ValorRegistro { $script:Reg["$Raiz\$SubChave|$Nome".ToLower()] = $Valor }
        Mock Get-ValorRegistro {
            $k = "$Caminho|$Nome".ToLower()
            if ($script:Reg.ContainsKey($k)) { [pscustomobject]@{ ChaveExiste = $true; Existe = $true; Valor = $script:Reg[$k]; Tipo = 'DWord' } }
            else { [pscustomobject]@{ ChaveExiste = $false; Existe = $false; Valor = $null; Tipo = $null } }
        }
        Mock Invoke-NoHiveUsuario { & $ScriptBlock $script:RaizUsuario }
    }

    It 'I7 valor reconhecido e efeito no Iniciar declarado como não verificável' {
        Invoke-ItemUsuario -Sessao (New-SessaoTeste) -Alvo $script:Alvo -Itens @('I7', 'I11')
        $script:DadoUsuario = Get-DadoUsuario -Alvo $script:Alvo
        $r = @(Test-ItemInicializacao -Id I7 -Perfil (New-PerfilTeste) -Info $null)
        @($r | Where-Object Alterado).Count | Should -Be 1
        ($r | Where-Object { -not $_.Alterado }).Confianca | Should -Be 'baixa'
        (@(Test-ItemInicializacao -Id I11 -Perfil (New-PerfilTeste) -Info ([pscustomobject]@{ EditionId = 'Professional' }))).Alterado | Should -Be $true
    }
}

Describe 'Itens sem registro' {
    BeforeEach {
        $script:DadoUsuario = $null
        $script:MotivoUsuario = 'usuário alvo não identificado'
    }

    It 'A1: ausentes no bloco 1, presente com motivo no bloco 2 (instalado, protegido, sem Store)' {
        $presente = [pscustomobject]@{ Instalados = @([pscustomobject]@{ Name = 'Microsoft.BingWeather'; NonRemovable = $false; IsFramework = $false; SignatureKind = 'Store'; InstallLocation = 'X' }); Provisionados = @() }
        Mock Get-PacoteAppx { if ($Nome -eq 'Microsoft.BingWeather') { $presente } else { [pscustomobject]@{ Instalados = @(); Provisionados = @() } } }
        Mock Get-NomeExibicaoAppx { [pscustomobject]@{ Nome = 'Clima'; Fabricante = 'Microsoft Corporation' } }
        $r = @(Test-ItemAplicativo -Id A1 -Perfil (New-PerfilTeste) -Loja $true)
        ($r | Where-Object Alterado).Texto | Should -Match "$($script:ListaA1.Count - 1) de $($script:ListaA1.Count)"
        ($r | Where-Object { -not $_.Alterado }).Texto | Should -Match 'Clima \(Microsoft.BingWeather\) ainda instalado'

        $prot = New-PerfilTeste -Protegidos @{ Aplicativos = @('Clima') }
        (@(Test-ItemAplicativo -Id A1 -Perfil $prot -Loja $true) | Where-Object { -not $_.Alterado }).Texto | Should -Match 'mantido por regra, protegido no perfil'
        (@(Test-ItemAplicativo -Id A1 -Perfil (New-PerfilTeste) -Loja $false) | Where-Object { -not $_.Alterado }).Texto | Should -Match 'sem Microsoft Store'
    }

    It 'A2: removido no bloco 1; EXE e ferramenta do fabricante no bloco 2' {
        Mock Get-ProgramaMaquina {
            [pscustomobject]@{ Nome = 'Fabricante Jogos'; Fabricante = 'Fabricante'; Versao = '1.0'; Tipo = 'EXE'; Id = 'Jogos'; Desinstalar = 'x' }
            [pscustomobject]@{ Nome = 'Dell Command | Update'; Fabricante = 'Dell'; Versao = '5'; Tipo = 'MSI'; Id = '{00000000-0000-0000-0000-000000000001}'; Desinstalar = 'x' }
        }
        $p = New-PerfilTeste -Opcoes @{ A2Remover = @('Removido*', 'Fabricante Jogos', 'Dell Command*') }
        $r = @(Test-ItemAplicativo -Id A2 -Perfil $p -Loja $true)
        ($r | Where-Object Alterado).Texto | Should -Match 'Removido\* não está mais instalado'
        ($r | Where-Object { -not $_.Alterado } | ForEach-Object Texto) -join '|' | Should -Match 'instalador EXE.*\|.*ferramenta de driver'
    }

    It 'I1: desabilitada, componente do Windows, não encontrada e usuário não verificável' {
        Mock Get-EstadoEntradaInicializacao {
            [pscustomobject]@{ Nome = 'Atualizador'; Comando = 'C:\Program Files\X\up.exe'; Desabilitada = $true }
            [pscustomobject]@{ Nome = 'SecurityHealth'; Comando = "$env:windir\System32\SecurityHealthSystray.exe"; Desabilitada = $false }
        }
        $p = New-PerfilTeste -Opcoes @{ I1Desabilitar = @('Atualizador', 'SecurityHealth', 'Sumiu') }
        $r = @(Test-ItemInicializacao -Id I1 -Perfil $p -Info $null)
        ($r | Where-Object Alterado).Texto | Should -Match 'Atualizador'
        ($r | Where-Object { -not $_.Alterado } | ForEach-Object Texto) -join '|' | Should -Match 'SecurityHealth mantido por regra'
        ($r | Where-Object { $_.Texto -match 'não verificáveis' }).Confianca | Should -Be ''
    }

    It 'I9 e I10: estado real da tarefa e do serviço' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = if ($TaskName -eq 'Desligada') { 'Disabled' } else { 'Ready' } } }
        $p = New-PerfilTeste -Opcoes @{ I9Tarefas = @('\Fab\Desligada', '\Fab\Ligada', '\Microsoft\Windows\X') }
        $r = @(Test-ItemInicializacao -Id I9 -Perfil $p -Info $null)
        @($r | Where-Object Alterado).Count | Should -Be 1
        ($r | Where-Object { -not $_.Alterado } | ForEach-Object Texto) -join '|' | Should -Match 'ainda habilitada.*\|.*tarefa do Windows'

        Mock Get-InicioServico { [pscustomobject]@{ Start = 3; Atrasado = $false; Tipo = 0x10; ImagePath = 'C:\Program Files\F\s.exe' } }
        $p = New-PerfilTeste -Opcoes @{ I10Servicos = @{ FabSvc = 'Manual'; OutroSvc = 'Disabled' } }
        $r = @(Test-ItemInicializacao -Id I10 -Perfil $p -Info $null)
        ($r | Where-Object Alterado).Texto | Should -Match 'FabSvc com início Manual'
        ($r | Where-Object { -not $_.Alterado }).Texto | Should -Match 'OutroSvc não aplicado \(início Manual, esperado Desativado\)'
    }

    It 'V3: projeto, alternativa Alto desempenho, Modern Standby e não aplicado' {
        Mock Get-CapacidadeEnergia { [pscustomobject]@{ ModernStandby = $script:Ms; Hibernacao = $false; S3 = $true } }
        Mock Get-PlanoAtivo { $script:Plano }
        Mock Test-PlanoExiste { $false }
        $casos = @(
            @{ Plano = $script:GuidPlanoProjeto; Ms = $false; Alterado = $true }
            @{ Plano = $script:GuidAltoDesempenho; Ms = $true; Alterado = $true }
            @{ Plano = $script:GuidEquilibrado; Ms = $true; Alterado = $false; Texto = 'Modern Standby' }
            @{ Plano = $script:GuidEquilibrado; Ms = $false; Alterado = $false; Texto = 'plano ativo: Equilibrado' }
        )
        foreach ($c in $casos) {
            $script:Ms = $c.Ms
            $script:Plano = $c.Plano
            $r = @(Test-ItemVisualEnergia -Id V3 -Perfil (New-PerfilTeste) -Info $null)
            $r.Alterado | Should -Be $c.Alterado
            if ($c.Texto) { $r.Texto | Should -Match $c.Texto }
        }
    }

    It 'V6 notebook é regra do projeto; V7 aceita 2147483650 (0x80000002)' {
        Mock Get-TipoEquipamento { 'Notebook' }
        (@(Test-ItemVisualEnergia -Id V6 -Perfil (New-PerfilTeste) -Info $null)).Texto | Should -Match 'regra, notebook'
        Test-BitLigado ([pscustomobject]@{ Existe = $true; Valor = '2147483650' }) 2 | Should -Be $true
        Test-BitLigado ([pscustomobject]@{ Existe = $true; Valor = '0' }) 2 | Should -Be $false
    }

    It 'Usuário alvo indisponível: itens do usuário não verificáveis, sem confiança' {
        $r = @(Test-ItemVisualEnergia -Id V2 -Perfil (New-PerfilTeste) -Info $null)
        $r.Alterado | Should -Be $false
        $r.Texto | Should -Match 'não verificável, usuário alvo não identificado'
        $r.Confianca | Should -Be ''
    }

    It 'Limpeza: L1 restos com média, L3, L4 e L7 não verificáveis, L6 ausente, L8 SSD e HDD' {
        Mock Get-ArquivoLimpeza { [pscustomobject]@{ Length = 2MB } }
        $r = @(Test-ItemLimpeza -Id L1 -IdadeMinimaDias 7)
        $r.Alterado | Should -Be $false; $r.Confianca | Should -Be 'média'; $r.Texto | Should -Match '1 arquivo\(s\), 2 MB'
        foreach ($id in 'L3', 'L4', 'L7') { (@(Test-ItemLimpeza -Id $id)).Texto | Should -Match 'não verificável' }
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*Windows.old' }
        (@(Test-ItemLimpeza -Id L6)).Alterado | Should -Be $true

        Mock Get-UnidadeFixa { 'C', 'D', 'E' }
        Mock Get-MidiaUnidade { switch ($Letra) { 'C' { 'SSD' } 'D' { 'HDD' } default { 'Unspecified' } } }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0; DefragRecommended = $false } }
        $r = @(Test-ItemLimpeza -Id L8)
        @($r | Where-Object Alterado).Count | Should -Be 2
        ($r | Where-Object { -not $_.Alterado }).Texto | Should -Match 'E: tipo de mídia não identificado'
        Should -Invoke Invoke-CimMethod -Times 1 -ParameterFilter { $MethodName -eq 'DefragAnalysis' -and $Query -like "*DriveLetter='D:'*" }
    }

    It 'Erro de leitura num item vira linha do bloco 2 e não interrompe' {
        $r = Invoke-Checagem -Item L6 -Acao { throw 'acesso negado' }
        $r.Alterado | Should -Be $false
        $r.Texto | Should -Match 'erro ao verificar \(acesso negado\)'
    }
}

Describe 'Sessões: executado, revertido e não executado' {
    BeforeEach {
        $script:raiz = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:raiz 'T') | Out-Null
        Mock Get-InfoWindows { [pscustomobject]@{ Build = 26100; UBR = 1; EditionId = 'Professional' } }
        Mock Get-UsuarioAlvo { throw 'sem usuário' }
        Mock Get-ValorRegistro { [pscustomobject]@{ ChaveExiste = $false; Existe = $false; Valor = $null; Tipo = $null } }
    }

    It 'Sem sessão: script não executado e itens não verificados' {
        $r = @(Get-ResultadoVerificacao -Perfil (New-PerfilTeste -Aplicar 'L9') -Raiz $script:raiz)
        $r.Count | Should -Be 1
        $r[0].Texto | Should -Match 'Limpeza não foi executado neste PC'
    }

    It 'Sessão mais recente revertida: revertido; sessão de reversão é ignorada' {
        $a = New-Item -ItemType Directory -Path (Join-Path $script:raiz 'T\20261009-100000-Limpeza')
        New-Item -ItemType Directory -Path (Join-Path $script:raiz 'T\20261009-110000-Limpeza-Reversao') | Out-Null
        Set-Content -LiteralPath (Join-Path $a.FullName 'revertido.txt') -Value 'x'
        $r = @(Get-ResultadoVerificacao -Perfil (New-PerfilTeste -Aplicar 'L9') -Raiz $script:raiz)
        $r[0].Texto | Should -Match 'foi revertido \(sessão de 09/10/2026 10:00\)'
    }

    It 'Aplicação posterior à reversão: verifica os itens' {
        $a = New-Item -ItemType Directory -Path (Join-Path $script:raiz 'T\20261009-100000-Limpeza')
        Set-Content -LiteralPath (Join-Path $a.FullName 'revertido.txt') -Value 'x'
        New-Item -ItemType Directory -Path (Join-Path $script:raiz 'T\20261009-120000-Limpeza') | Out-Null
        $r = @(Get-ResultadoVerificacao -Perfil (New-PerfilTeste -Aplicar 'L9', 'L3') -Raiz $script:raiz)
        ($r | ForEach-Object Item) -join ',' | Should -Be 'L3,L9'
        ($r | Where-Object Item -eq 'L9').Texto | Should -Match 'não aplicado'
    }
}

Describe 'Mensagem em dois blocos' {
    It 'Blocos, contagens, confiança e relatório UTF-8' {
        $r = @(
            New-Verificado -Item L6 -Detalhe 'removida.'
            New-Verificado -Item L1 -Detalhe 'nenhum arquivo.' -Confianca 'média'
            New-Pendente -Item L3 -Detalhe 'não verificável, o cache se refaz.' -Confianca ''
        )
        $t = Format-Verificacao -Resultados $r -Perfil (New-PerfilTeste) -Usuario 'PC\joão'
        $i1 = [array]::IndexOf($t, '1. ALTERADO (2)'); $i2 = [array]::IndexOf($t, '2. NÃO ALTERADO OU COM ERRO (1)')
        $i1 | Should -BeGreaterThan 0; $i2 | Should -BeGreaterThan $i1
        $t[$i1 + 2] | Should -Be '  [L1] Temporários do Windows: nenhum arquivo. (confiança média)'
        $t[$i2 + 1] | Should -Be '  [L3] Cache dos navegadores: não verificável, o cache se refaz.'
        @($t | Where-Object { $_ -match '[\u2013\u2014]' }) | Should -BeNullOrEmpty

        $arq = Join-Path $TestDrive 'rel.txt'
        [IO.File]::WriteAllLines($arq, $t, (New-Object Text.UTF8Encoding $true))
        [IO.File]::ReadAllText($arq, [Text.Encoding]::UTF8) | Should -Match 'joão'
    }

    It 'Sem pendências: mensagem de tudo aplicado' {
        $t = Format-Verificacao -Resultados @(New-Verificado -Item L6 -Detalhe 'removida.') -Perfil (New-PerfilTeste)
        $t -join "`n" | Should -Match 'Nada pendente'
    }
}

Describe 'Execução real (somente leitura)' {
    It 'Sem administrador (mock): aborta antes de ler o perfil' {
        Mock Test-Administrador { $false }
        Mock Import-PerfilCliente { }
        { Invoke-Verificacao -Perfil 'x.psd1' -IdadeMinimaDias 7 } | Should -Throw '*Execute como administrador*'
        Should -Invoke Import-PerfilCliente -Times 0
    }

    It 'Sem administrador: aborta com mensagem clara' {
        if (Test-Administrador) { Set-ItResult -Skipped -Because 'processo elevado' ; return }
        $saida = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Fonte -Perfil (Join-Path $PSScriptRoot '..\perfis\exemplo.psd1') 2>&1 | Out-String
        $saida | Should -Match 'Execute como administrador'
    }
}
