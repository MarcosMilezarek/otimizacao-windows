# Menu.ps1 registra tarefas e reinicia: executar SOMENTE na VM de teste (tools\Testar-NaVM.ps1 define OTIMIZACAO_VM=1).
# Reinicializações e scripts de otimização são simulados por Mock; a tarefa agendada, o icacls e a mensagem são reais.
BeforeAll {
    if ($env:OTIMIZACAO_VM -ne '1') { throw 'Menu.Tests.ps1 só pode rodar na VM de teste (OTIMIZACAO_VM=1).' }
    . (Join-Path $PSScriptRoot '..\src\Menu.ps1')
    $script:Fonte = Join-Path $PSScriptRoot '..\src\Menu.ps1'
    $script:Utf8Bom = New-Object Text.UTF8Encoding $true

    function New-ArquivoPerfil {
        param([string]$Sid = '', [string[]]$Aplicar = @('I5', 'L9'))
        $a = Join-Path $TestDrive ('perfil-' + [guid]::NewGuid() + '.psd1')
        $lista = ($Aplicar | ForEach-Object { "'$_'" }) -join ', '
        [IO.File]::WriteAllText($a, "@{`r`n    Cliente    = 'E2E'`r`n    UsuarioSid = '$Sid'`r`n    Aplicar    = @($lista)`r`n    Pular      = @()`r`n}`r`n", $script:Utf8Bom)
        $a
    }

    function New-FluxoTeste {
        <# Pasta e estado de fluxo em TestDrive, sem tarefa nem cópia de src. #>
        param([string[]]$Scripts = @('Manutencao', 'Limpeza'))
        $script:RaizFluxo = Join-Path $TestDrive ('raiz-' + [guid]::NewGuid())
        $pasta = Join-Path $script:RaizFluxo 'E2E\20261009-100000-Fluxo'
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
        $estado = [pscustomobject]@{
            Cliente = 'E2E'; Computador = 'PC'; PerfilOrigem = 'x'; Perfil = 'x.psd1'; UsuarioSid = 'S-1-5-21-1-2-3-1001'; IniciadoPor = 't'
            Inicio = (Get-Date).ToString('s'); Fim = $null; Status = 'EmAndamento'; Motivo = $null; MensagemExibida = $false
            Indice = 0; Reinicializacoes = 0; AguardarUptimeMinutos = 10; AmostraSegundos = 300; Etapas = @(Get-PlanoFluxo -Scripts $Scripts)
        }
        Save-EstadoFluxo -Pasta $pasta -Estado $estado
        $pasta
    }

    function Invoke-AteParar {
        <# Simula os boots: chama o fluxo até ele sair de EmAndamento (cada chamada vai até uma reinicialização). #>
        param([string]$Pasta, [int]$Maximo = 30)
        for ($i = 0; $i -lt $Maximo; $i++) {
            Invoke-FluxoOtimizacao -Pasta $Pasta
            $e = Get-EstadoFluxo -Pasta $Pasta
            if ($e.Status -ne 'EmAndamento') { return $e }
        }
        throw 'O fluxo não terminou.'
    }

    function Get-Argumento { param([string[]]$Lista, [string]$Nome) $Lista[[array]::IndexOf($Lista, $Nome) + 1] }

    # Simula os processos das etapas: Coleta gera JSON, comparação gera HTML, Verificacao gera o relatório,
    # scripts devolvem o código em $script:Codigos (padrão 0). Manutencao com $script:CriarAchado grava um achado no log.
    function Set-MockProcesso {
        $script:Codigos = @{}
        $script:CriarAchado = $false
        Mock Invoke-ProcessoEtapa {
            [IO.File]::WriteAllLines($Saida, [string[]]@('saída da etapa', 'última linha'), $script:Utf8Bom)
            $nome = Split-Path -Leaf $Arquivo
            if ($nome -eq 'Coleta.ps1' -and $Argumentos -contains '-Comparar') { if (-not $script:FalharComparacao) { Set-Content -LiteralPath (Get-Argumento $Argumentos '-SaidaHtml') -Value 'html' } }
            elseif ($nome -eq 'Coleta.ps1') { if (-not $script:FalharColeta) { Set-Content -LiteralPath (Join-Path (Get-Argumento $Argumentos '-PastaSaida') 'c.json') -Value '{}' } }
            elseif ($nome -eq 'Verificacao.ps1') { [IO.File]::WriteAllLines((Get-Argumento $Argumentos '-Relatorio'), [string[]]@('Verificação final da otimização', '1. ALTERADO (1)'), $script:Utf8Bom) }
            elseif ($nome -eq 'Manutencao.ps1' -and $script:CriarAchado) {
                $sessao = New-Item -ItemType Directory -Path (Join-Path $script:RaizFluxo ('E2E\{0}-Manutencao' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
                [pscustomobject]@{ Data = 'x'; Item = 'M1'; Alvo = 'Imagem'; ValorAnterior = 'Repairable'; ValorNovo = ''; Resultado = 'Info'; Detalhe = 'ATENÇÃO: Corrupção reparável.' } |
                    Export-Csv -LiteralPath (Join-Path $sessao.FullName 'log.csv') -NoTypeInformation -Encoding UTF8
            }
            if ($script:Codigos.ContainsKey($nome)) { $script:Codigos[$nome] } else { 0 }
        }
    }
}

Describe 'Plano do fluxo' {
    It 'Só scripts com item que altera o sistema, na ordem aprovada, respeitando Pular' {
        $p = [pscustomobject]@{ Aplicar = @('L9', 'M5', 'A3', 'V2', 'I5', 'M4'); Pular = @('V2') }
        (Get-ScriptAplicavel -Perfil $p) -join ',' | Should -Be 'Manutencao,Inicializacao,Limpeza'
    }

    It 'Etapas: coletas antes com reinicialização, scripts, reinicialização final, coleta depois, comparação e verificação por último' {
        $tipos = (Get-PlanoFluxo -Scripts 'Manutencao', 'Limpeza' | ForEach-Object { $_.Tipo }) -join ','
        $tipos | Should -Be 'Reiniciar,Coleta,Reiniciar,Coleta,Reiniciar,Script,Script,Reiniciar,Coleta,Comparar,Verificar'
        (Get-PlanoFluxo -Scripts 'Limpeza' | Where-Object Tipo -eq 'Coleta' | ForEach-Object { $_.Rotulo }) -join ',' | Should -Be 'antes1,antes2,depois'
    }
}

Describe 'Perfil congelado' {
    It 'UsuarioSid vazio recebe o SID informado' {
        $d = Join-Path $TestDrive 'c1.psd1'
        Copy-PerfilFluxo -Origem (New-ArquivoPerfil) -Destino $d -UsuarioSid 'S-1-5-21-111-222-333-1001'
        (Import-PerfilCliente -Caminho $d).UsuarioSid | Should -Be 'S-1-5-21-111-222-333-1001'
    }
    It 'SID fora do formato é recusado' {
        { Copy-PerfilFluxo -Origem (New-ArquivoPerfil) -Destino (Join-Path $TestDrive 'c2.psd1') -UsuarioSid "S-1-5-21-1'; x" } | Should -Throw '*fora do formato*'
    }
    It 'Perfil sem a linha UsuarioSid é recusado' {
        $a = Join-Path $TestDrive 'semsid.psd1'
        [IO.File]::WriteAllText($a, "@{ Cliente = 'E2E'; Aplicar = @('L9') }", $script:Utf8Bom)
        { Copy-PerfilFluxo -Origem $a -Destino (Join-Path $TestDrive 'c3.psd1') -UsuarioSid 'S-1-5-21-1-2-3-1001' } | Should -Throw '*UsuarioSid*'
    }
}

Describe 'Sem prompt depois da escolha (análise estática)' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Fonte, [ref]$null, [ref]$null)
        $script:Chamadas = @{}
        foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $script:Chamadas[$f.Name] = @($f.Body.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        }
        $script:TodosComandos = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    }

    It 'Nada alcançável a partir da tarefa (Invoke-FluxoOtimizacao) pede entrada' {
        $vistos = New-Object System.Collections.Generic.HashSet[string]
        $fila = New-Object System.Collections.Generic.Queue[string]
        $fila.Enqueue('Invoke-FluxoOtimizacao')
        while ($fila.Count) {
            $f = $fila.Dequeue()
            if (-not $vistos.Add($f)) { continue }
            foreach ($c in @($script:Chamadas[$f])) { if ($script:Chamadas.ContainsKey($c)) { $fila.Enqueue($c) } elseif ($c) { [void]$vistos.Add($c) } }
        }
        @($vistos | Where-Object { $_ -in 'Read-Host', 'Get-Credential', 'Out-GridView', 'pause', 'Initialize-Interface' -or $_ -like '*Menu*' -or $_ -like '*Janela*' }) | Should -BeNullOrEmpty
    }

    It 'Sem Read-Host: o menu é janela' {
        @($script:TodosComandos | Where-Object { $_ -eq 'Read-Host' }).Count | Should -Be 0
    }

    It 'Não usa travessão' {
        [IO.File]::ReadAllText($script:Fonte, [Text.Encoding]::UTF8) | Should -Not -Match '[–—]'
    }
}

Describe 'Execução das etapas (boots simulados)' {
    BeforeEach {
        Mock Restart-Fluxo { }
        Mock Show-MensagemUsuario { }
        Mock Remove-TarefaOtimizacao { }
        Mock Wait-Logon { $true }
        Mock Test-ReinicializacaoPendente { [pscustomobject]@{ ComponentBasedServicing = $false; WindowsUpdate = $false; RenomeacaoArquivos = $false } }
        $script:FalharColeta = $false
        $script:FalharComparacao = $false
        Set-MockProcesso
    }

    It 'Primeiro boot: etapa Reiniciar avança o índice e reinicia uma vez' {
        $pasta = New-FluxoTeste
        Invoke-FluxoOtimizacao -Pasta $pasta
        $e = Get-EstadoFluxo -Pasta $pasta
        $e.Indice | Should -Be 1
        $e.Reinicializacoes | Should -Be 1
        Should -Invoke Restart-Fluxo -Times 1
        Should -Invoke Invoke-ProcessoEtapa -Times 0
    }

    It 'Fluxo completo: conclui com verificação por último, mensagem aberta uma vez e tarefa removida' {
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Status | Should -Be 'Concluido'
        $e.MensagemExibida | Should -Be $true
        @($e.Etapas | Where-Object { $_.Status -ne 'OK' }) | Should -BeNullOrEmpty
        $e.Reinicializacoes | Should -Be 4
        Should -Invoke Restart-Fluxo -Times 4
        Should -Invoke Show-MensagemUsuario -Times 1
        Should -Invoke Remove-TarefaOtimizacao -ParameterFilter { $Nome -eq 'Fluxo' }
        $msg = [IO.File]::ReadAllText((Join-Path $pasta 'mensagem.txt'), [Text.Encoding]::UTF8)
        $msg | Should -Match 'Otimização concluída'
        $msg | Should -Match 'Verificação final da otimização'
        $msg | Should -Match 'comparacao\.html'
        # Ordem real de execução: Verificacao é o último processo chamado.
        Should -Invoke Invoke-ProcessoEtapa -Times 7
        $ultimo = @(Get-ChildItem -LiteralPath $pasta -Filter 'etapa-*.txt' | Sort-Object Name)[-1].Name
        $ultimo | Should -Match 'Verifica'
    }

    It 'Script com erro: interrompe, mostra o motivo e o que já foi aplicado, remove a tarefa' {
        $script:Codigos['Limpeza.ps1'] = 1
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Status | Should -Be 'Interrompido'
        $e.Motivo | Should -Be 'Limpeza terminou com erro (código 1).'
        $msg = [IO.File]::ReadAllText((Join-Path $pasta 'mensagem.txt'), [Text.Encoding]::UTF8)
        $msg | Should -Match 'Scripts concluídos antes da interrupção: Manutencao'
        $msg | Should -Match 'última linha'
        $msg | Should -Match 'Reverter'
        Should -Invoke Invoke-ProcessoEtapa -Times 0 -ParameterFilter { $Arquivo -like '*Verificacao.ps1' }
        Should -Invoke Remove-TarefaOtimizacao -ParameterFilter { $Nome -eq 'Fluxo' }
    }

    It 'Achado da Manutencao (corrupção ou erro de disco): interrompe antes dos outros scripts' {
        $script:CriarAchado = $true
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Status | Should -Be 'Interrompido'
        $e.Motivo | Should -Match '\[M1\] Imagem: Corrupção reparável'
        Should -Invoke Invoke-ProcessoEtapa -Times 0 -ParameterFilter { $Arquivo -like '*Limpeza.ps1' }
    }

    It 'Reinicialização pendente: reinicia antes do script no máximo 2 vezes e depois interrompe' {
        Mock Test-ReinicializacaoPendente { [pscustomobject]@{ ComponentBasedServicing = $false; WindowsUpdate = $true; RenomeacaoArquivos = $false } }
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Status | Should -Be 'Interrompido'
        $e.Motivo | Should -Match 'continua depois de 2 reinicializações'
        $e.Etapas[5].Tentativas | Should -Be 2
        Should -Invoke Restart-Fluxo -Times 5
        Should -Invoke Invoke-ProcessoEtapa -Times 0 -ParameterFilter { $Arquivo -like '*Manutencao.ps1' }
    }

    It 'Coleta sem arquivo: interrompe' {
        $script:FalharColeta = $true
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Motivo | Should -Match 'Coleta antes 1 não gerou o arquivo'
    }

    It 'Comparação falha: segue para a verificação e avisa na mensagem' {
        $script:FalharComparacao = $true
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Status | Should -Be 'Concluido'
        [IO.File]::ReadAllText((Join-Path $pasta 'mensagem.txt'), [Text.Encoding]::UTF8) | Should -Match 'Comparação de desempenho não gerada'
    }

    It 'Cancelado no menu: não executa nada, não reinicia e remove a tarefa' {
        $pasta = New-FluxoTeste
        $e = Get-EstadoFluxo -Pasta $pasta; $e.Status = 'Cancelado'; Save-EstadoFluxo -Pasta $pasta -Estado $e
        Invoke-FluxoOtimizacao -Pasta $pasta
        Should -Invoke Restart-Fluxo -Times 0
        Should -Invoke Invoke-ProcessoEtapa -Times 0
        Should -Invoke Show-MensagemUsuario -Times 0
        Should -Invoke Remove-TarefaOtimizacao -Times 1 -ParameterFilter { $Nome -eq 'Fluxo' }
    }

    It 'Interrompido sem ninguém conectado e PC reiniciado: o boot seguinte mostra a mensagem pendente' {
        $pasta = New-FluxoTeste
        $e = Get-EstadoFluxo -Pasta $pasta; $e.Status = 'Interrompido'; Save-EstadoFluxo -Pasta $pasta -Estado $e
        Invoke-FluxoOtimizacao -Pasta $pasta
        Should -Invoke Show-MensagemUsuario -Times 1
        (Get-EstadoFluxo -Pasta $pasta).MensagemExibida | Should -Be $true
        Invoke-FluxoOtimizacao -Pasta $pasta
        Should -Invoke Show-MensagemUsuario -Times 1
    }

    It 'Erro inesperado numa etapa: interrompe com o erro na mensagem' {
        Mock Invoke-EtapaFluxo { throw 'falha simulada' }
        $pasta = New-FluxoTeste
        $e = Invoke-AteParar -Pasta $pasta
        $e.Motivo | Should -Be 'Erro inesperado no fluxo: falha simulada'
        Should -Invoke Show-MensagemUsuario -Times 1
    }
}

# Fora do Describe acima: lá o BeforeEach substitui Wait-Logon por Mock.
Describe 'Espera de logon' {
    It 'Espera de logon termina se o fluxo for cancelado' {
        Mock Get-UsuarioConectado { '' }
        $pasta = New-FluxoTeste
        $e = Get-EstadoFluxo -Pasta $pasta; $e.Status = 'Cancelado'; Save-EstadoFluxo -Pasta $pasta -Estado $e
        Wait-Logon -Pasta $pasta -IntervaloSegundos 1 | Should -Be $false
    }
}

Describe 'Usuário conectado por sessão (console, Área de Trabalho Remota, AnyDesk)' {
    It 'Sessão remota ativa conta, mesmo com o console sem usuário' {
        Mock Get-SessaoInterativa { [pscustomobject]@{ Id = 2; Estado = 0; Usuario = 'PC\marco' } }
        Get-UsuarioConectado | Should -Be 'PC\marco'
    }

    It 'Sessão desconectada e sessão 0 não contam; com duas ativas vale a de menor Id' {
        Mock Get-SessaoInterativa {
            [pscustomobject]@{ Id = 0; Estado = 0; Usuario = 'NT AUTHORITY\SYSTEM' }
            [pscustomobject]@{ Id = 1; Estado = 4; Usuario = 'PC\antigo' }
            [pscustomobject]@{ Id = 5; Estado = 0; Usuario = 'PC\segundo' }
            [pscustomobject]@{ Id = 3; Estado = 0; Usuario = 'PC\primeiro' }
        }
        Get-UsuarioConectado | Should -Be 'PC\primeiro'
    }

    It 'Sem sessão com usuário devolve vazio e Wait-Logon espera' {
        Mock Get-SessaoInterativa { }
        Get-UsuarioConectado | Should -Be ''
        $pasta = New-FluxoTeste
        $e = Get-EstadoFluxo -Pasta $pasta; $e.Status = 'Cancelado'; Save-EstadoFluxo -Pasta $pasta -Estado $e
        Wait-Logon -Pasta $pasta -IntervaloSegundos 1 | Should -Be $false
    }

    It 'API WTS real: devolve objetos com Id, Estado e Usuario e não inclui a sessão 0 sem usuário' {
        $s = @(Get-SessaoInterativa)
        foreach ($x in $s) { $x.PSObject.Properties.Name | Should -Be @('Id', 'Estado', 'Usuario') }
        @($s | Where-Object { -not $_.Usuario }) | Should -BeNullOrEmpty
    }
}

Describe 'Acompanhamento do fluxo' {
    BeforeEach {
        $script:Pasta = New-FluxoTeste -Scripts @('Manutencao')
        $e = Get-EstadoFluxo -Pasta $script:Pasta
        $e.Indice = 1
        $e.Etapas[0].Status = 'OK'; $e.Etapas[0].Inicio = '2026-10-19T10:54:47'; $e.Etapas[0].Fim = '2026-10-19T10:54:48'
        $e.Etapas[1].Status = 'Executando'; $e.Etapas[1].Inicio = '2026-10-19T10:55:33'
        Save-EstadoFluxo -Pasta $script:Pasta -Estado $e
        Write-RegistroFluxo -Pasta $script:Pasta -Texto 'linha de teste um'
        Write-RegistroFluxo -Pasta $script:Pasta -Texto 'linha de teste dois'
    }

    It 'Linhas: status e horas de cada etapa e a etapa atual marcada, sem alterar o estado' {
        $antes = [IO.File]::ReadAllText((Join-Path $script:Pasta 'fluxo.json'), [Text.Encoding]::UTF8)
        $l = @(Get-LinhaAcompanhamento -Estado (Get-EstadoFluxo -Pasta $script:Pasta))
        $l.Count | Should -Be 10
        $l[0].Status | Should -Be 'OK'; $l[0].Inicio | Should -Be '10:54:47'; $l[0].Fim | Should -Be '10:54:48'
        $l[1].Nome | Should -Be 'Coleta antes 1'; $l[1].Status | Should -Be 'Executando'; $l[1].Atual | Should -BeTrue
        @($l | Where-Object Atual).Count | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $script:Pasta 'fluxo.json'), [Text.Encoding]::UTF8) | Should -Be $antes
    }

    It 'Cabeçalho: etapa atual, dica da coleta e contagem; fim do log' {
        $c = Get-CabecalhoAcompanhamento -Estado (Get-EstadoFluxo -Pasta $script:Pasta)
        $c.Atual | Should -Be 'Etapa 2 de 10: Coleta antes 1.'
        $c.Dica | Should -Match 'espera 10 min'
        $c.Concluidas | Should -Be 1
        $c.Total | Should -Be 10
        (Get-FimLogFluxo -Pasta $script:Pasta) -join "`n" | Should -Match 'linha de teste dois'
    }

    It 'Fluxo terminado: sem etapa atual, com o motivo' {
        $e = Get-EstadoFluxo -Pasta $script:Pasta; $e.Status = 'Interrompido'; $e.Motivo = 'motivo teste'; Save-EstadoFluxo -Pasta $script:Pasta -Estado $e
        $e = Get-EstadoFluxo -Pasta $script:Pasta
        @(Get-LinhaAcompanhamento -Estado $e | Where-Object Atual).Count | Should -Be 0
        $c = Get-CabecalhoAcompanhamento -Estado $e
        $c.Titulo | Should -Match 'Fluxo interrompido'
        $c.Atual | Should -Be 'Motivo: motivo teste'
    }

    It 'Cancelar: grava Cancelado, registra no log e remove as tarefas' {
        Mock Remove-TarefasFluxo { }
        Stop-FluxoMenu -Fluxo ([pscustomobject]@{ Pasta = $script:Pasta; Estado = (Get-EstadoFluxo -Pasta $script:Pasta) })
        (Get-EstadoFluxo -Pasta $script:Pasta).Status | Should -Be 'Cancelado'
        [IO.File]::ReadAllText((Join-Path $script:Pasta 'fluxo.log'), [Text.Encoding]::UTF8) | Should -Match 'Cancelado no menu'
        Should -Invoke Remove-TarefasFluxo -Times 1 -Exactly
    }

    It 'Menu com fluxo em andamento abre o acompanhamento; cancelado, volta aos perfis' {
        Mock Test-Administrador { $true }
        Mock Initialize-Interface { }
        $script:NAndamento = 0
        Mock Get-FluxoEmAndamento { $script:NAndamento++; if ($script:NAndamento -eq 1) { [pscustomobject]@{ Pasta = $script:Pasta; Estado = $null } } }
        Mock Show-JanelaAcompanhamento { $true }
        Mock Show-JanelaMenu { $false }
        Show-MenuPrincipal
        Should -Invoke Show-JanelaAcompanhamento -Times 1 -Exactly -ParameterFilter { $Pasta -eq $script:Pasta -and $PermitirCancelar }
        Should -Invoke Show-JanelaMenu -Times 1 -Exactly
    }

    It 'Menu com fluxo em andamento: fechar o acompanhamento sem cancelar sai do menu' {
        Mock Test-Administrador { $true }
        Mock Initialize-Interface { }
        Mock Get-FluxoEmAndamento { [pscustomobject]@{ Pasta = $script:Pasta; Estado = $null } }
        Mock Show-JanelaAcompanhamento { $false }
        Mock Show-JanelaMenu { $false }
        Show-MenuPrincipal
        Should -Invoke Show-JanelaMenu -Times 0
    }

    It 'Janela da tarefa: Cancelar fluxo só para quem está elevado' {
        Mock Initialize-Interface { }
        Mock Show-JanelaAcompanhamento { $false }
        Mock Test-Administrador { $false }
        Invoke-Acompanhar -Pasta $script:Pasta
        Should -Invoke Show-JanelaAcompanhamento -Times 1 -Exactly -ParameterFilter { -not $PermitirCancelar }
    }
}

Describe 'Ações do menu (Pester, mocks e processo real)' {
    It 'Reverter: só scripts com sessão não revertida, na ordem inversa do fluxo' {
        $raiz = Join-Path $TestDrive ('rev-' + [guid]::NewGuid())
        foreach ($s in '20261019-100000-Manutencao', '20261019-100100-Limpeza', '20261019-100200-Inicializacao') { New-Item -ItemType Directory -Path (Join-Path $raiz "E2E\$s") -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $raiz 'E2E\20261019-100200-Inicializacao\revertido.txt') -Value 'x'
        (Get-PendenteReversao -Cliente 'E2E' -Raiz $raiz) -join ',' | Should -Be 'Limpeza,Manutencao'
    }

    It 'Condição do fluxo: sem item, bloqueio e usuário inválido viram Erro; tudo certo traz os scripts e o usuário' {
        (Get-CondicaoFluxo -Perfil ([pscustomobject]@{ Aplicar = @('A3'); Pular = @() })).Erro | Should -Match 'Nenhum item'
        Mock Test-PreCondicao { [pscustomobject]@{ Avisos = @('aviso x'); Bloqueios = @('bloqueio y') } }
        $c = Get-CondicaoFluxo -Perfil ([pscustomobject]@{ Aplicar = @('L1'); Pular = @() })
        $c.Erro | Should -Match 'bloqueios'
        $c.Bloqueios | Should -Be 'bloqueio y'
        Mock Test-PreCondicao { [pscustomobject]@{ Avisos = @('aviso x'); Bloqueios = @() } }
        Mock Resolve-UsuarioFluxo { throw 'Sem usuário conectado.' }
        (Get-CondicaoFluxo -Perfil ([pscustomobject]@{ Aplicar = @('L1'); Pular = @() })).Erro | Should -Match 'Usuário alvo: Sem usuário'
        Mock Resolve-UsuarioFluxo { [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Nome = 'PC\cliente'; DoPerfil = $false } }
        $c = Get-CondicaoFluxo -Perfil ([pscustomobject]@{ Aplicar = @('L1', 'M3'); Pular = @() })
        $c.Erro | Should -BeNullOrEmpty
        $c.Scripts -join ',' | Should -Be 'Manutencao,Limpeza'
        $c.Avisos | Should -Be 'aviso x'
        $c.Usuario.Sid | Should -Be 'S-1-5-21-1-2-3-1001'
    }

    It 'Argumentos do processo: com espaço ou vazio entre aspas' {
        Join-ArgumentoProcesso -Argumentos '-File', 'C:\Program Files\x.ps1', '-WhatIf', '' | Should -Be '-File "C:\Program Files\x.ps1" -WhatIf ""'
    }

    It 'Processo real: saída, avisos e erros com acentos na página de código do sistema, e o código de saída' {
        $s = Join-Path $TestDrive 'filho com espaço.ps1'
        [IO.File]::WriteAllText($s, "param([string]`$Perfil)`r`nWrite-Host 'host: ação'`r`n`"saída: `$Perfil`"`r`nWrite-Warning 'atenção'`r`nWrite-Error 'erro: é'`r`nexit 3`r`n", $script:Utf8Bom)
        $x = Start-ProcessoScript -Arquivo $s -Argumentos @('-Perfil', 'C:\perfis\São Paulo.psd1')
        $linhas = New-Object System.Collections.Generic.List[string]
        $limite = (Get-Date).AddSeconds(60)
        do { $r = Read-SaidaProcesso -Execucao $x; foreach ($l in $r.Linhas) { $linhas.Add($l) }; Start-Sleep -Milliseconds 100 } until ($r.Terminou -or (Get-Date) -gt $limite)
        $texto = $linhas -join "`n"
        Write-Host "Página OEM: $((Get-CodificacaoConsole).WebName)"
        $r.Terminou | Should -BeTrue
        $r.Codigo | Should -Be 3
        $texto | Should -Match 'host: ação'
        $texto | Should -Match ([regex]::Escape('saída: C:\perfis\São Paulo.psd1'))
        $texto | Should -Match 'atenção'
        $texto | Should -Match 'erro: é'
    }
}

Describe 'Registro do fluxo com a janela (Pester, mocks)' {
    It 'Falha ao registrar a janela não impede o fluxo e fica no log' {
        Mock Register-TarefaFluxo { }
        Mock Register-TarefaAcompanhar { throw 'sem permissão' }
        $raiz = Join-Path $TestDrive ('real-' + [guid]::NewGuid())
        $pasta = Start-FluxoOtimizacao -PerfilOrigem (New-ArquivoPerfil) -UsuarioSid 'S-1-5-21-1-2-3-1001' -Raiz $raiz
        (Get-EstadoFluxo -Pasta $pasta).Status | Should -Be 'EmAndamento'
        [IO.File]::ReadAllText((Join-Path $pasta 'fluxo.log'), [Text.Encoding]::UTF8) | Should -Match 'Janela de acompanhamento não registrada: sem permissão'
    }

    It 'Remove-TarefasFluxo remove a janela primeiro e a tarefa do fluxo por último' {
        $script:Ordem = New-Object System.Collections.Generic.List[string]
        Mock Remove-TarefaOtimizacao { $script:Ordem.Add($Nome) }
        Remove-TarefasFluxo
        $script:Ordem -join ',' | Should -Be 'Acompanhar,Fluxo'
    }
}

Describe 'Preparação real na VM' {
    BeforeAll {
        $script:SidCliente = (Get-LocalUser -Name cliente).SID.Value
        $script:RaizReal = Join-Path $env:ProgramData ('OtimizacaoTesteMenu-' + [guid]::NewGuid())
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Fluxo' -Confirm:$false -ErrorAction SilentlyContinue
    }
    AfterAll {
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Fluxo' -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Mensagem' -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Acompanhar' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:RaizReal -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Cria pasta restrita, cópia de src e do perfil, estado e tarefa SYSTEM no boot sem limite de tempo' {
        $pasta = Start-FluxoOtimizacao -PerfilOrigem (New-ArquivoPerfil) -UsuarioSid $script:SidCliente -Raiz $script:RaizReal
        $acl = Get-Acl -LiteralPath $pasta
        $acl.AreAccessRulesProtected | Should -Be $true
        $regras = @($acl.Access | ForEach-Object { [pscustomobject]@{ Sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value; Direitos = [string]$_.FileSystemRights } })
        ($regras | Where-Object Sid -eq 'S-1-5-32-545').Direitos | Should -Be 'ReadAndExecute, Synchronize'
        ($regras | Where-Object Sid -eq 'S-1-5-18').Direitos | Should -Be 'FullControl'
        @($regras | Where-Object { $_.Sid -notin 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545' }) | Should -BeNullOrEmpty
        foreach ($a in 'Menu.ps1', 'Verificacao.ps1', 'Otimizacao.Comum.psm1', 'Coleta.ps1', 'Limpeza.ps1') { Join-Path $pasta "src\$a" | Should -Exist }
        (Import-PerfilCliente -Caminho (Join-Path $pasta 'perfil.psd1')).UsuarioSid | Should -Be $script:SidCliente
        (Get-EstadoFluxo -Pasta $pasta).Status | Should -Be 'EmAndamento'

        $t = Get-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Fluxo'
        ([Security.Principal.NTAccount]$t.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-18'
        [string]$t.Principal.RunLevel | Should -Be 'Highest'
        $t.Triggers[0].CimClass.CimClassName | Should -Be 'MSFT_TaskBootTrigger'
        $t.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
        $t.Actions[0].Arguments | Should -Match ([regex]::Escape("-Continuar `"$pasta`""))

        # Janela de acompanhamento: logon do usuário alvo, logon interativo sem senha, elevada, sem limite de tempo.
        $a = Get-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Acompanhar'
        $a.Triggers[0].CimClass.CimClassName | Should -Be 'MSFT_TaskLogonTrigger'
        ([Security.Principal.NTAccount]$a.Triggers[0].UserId).Translate([Security.Principal.SecurityIdentifier]).Value | Should -Be $script:SidCliente
        ([Security.Principal.NTAccount]$a.Principal.UserId).Translate([Security.Principal.SecurityIdentifier]).Value | Should -Be $script:SidCliente
        [string]$a.Principal.LogonType | Should -Be 'Interactive'
        [string]$a.Principal.RunLevel | Should -Be 'Highest'
        $a.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
        $a.Actions[0].Arguments | Should -Match ([regex]::Escape("-Acompanhar `"$pasta`""))
        $a.Actions[0].Arguments | Should -Match '-WindowStyle Hidden'

        { Start-FluxoOtimizacao -PerfilOrigem (New-ArquivoPerfil) -UsuarioSid $script:SidCliente -Raiz $script:RaizReal } | Should -Throw '*fluxo em andamento*'

        Remove-TarefasFluxo
        Get-ScheduledTask -TaskPath '\Otimizacao\' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Processo da etapa: código de saída e saída gravada' {
        $s = Join-Path $script:RaizReal 'filho.ps1'
        New-Item -ItemType Directory -Path $script:RaizReal -Force | Out-Null
        [IO.File]::WriteAllText($s, "'linha um'`r`nWrite-Warning 'aviso'`r`nexit 3`r`n", $script:Utf8Bom)
        $saida = Join-Path $script:RaizReal 'saida.txt'
        Invoke-ProcessoEtapa -Arquivo $s -Argumentos @() -Saida $saida | Should -Be 3
        [IO.File]::ReadAllText($saida, [Text.Encoding]::UTF8) | Should -Match 'linha um'
    }

    It 'Mensagem abre no Bloco de Notas na sessão do usuário conectado e a tarefa temporária some' {
        $usuario = Get-UsuarioConectado
        if (-not $usuario) { Set-ItResult -Skipped -Because 'ninguém conectado ao console da VM'; return }
        $pasta = Join-Path $script:RaizReal 'msg'
        New-Item -ItemType Directory -Path $pasta -Force | Out-Null
        $arq = Join-Path $pasta 'mensagem.txt'
        [IO.File]::WriteAllLines($arq, [string[]]@('Teste da mensagem final', 'Otimização concluída'), $script:Utf8Bom)
        $antes = @(Get-Process -IncludeUserName | Where-Object { $_.ProcessName -like '*notepad*' } | ForEach-Object { $_.Id })
        Show-MensagemUsuario -Arquivo $arq -Pasta $pasta
        Start-Sleep -Seconds 5
        $novos = @(Get-Process -IncludeUserName | Where-Object { $_.ProcessName -like '*notepad*' -and $antes -notcontains $_.Id })
        Write-Host ("Bloco de Notas: " + (($novos | ForEach-Object { "$($_.ProcessName) pid $($_.Id) usuário $($_.UserName) sessão $($_.SessionId)" }) -join '; '))
        $novos.Count | Should -BeGreaterThan 0
        ($novos | Select-Object -First 1).UserName | Should -Be $usuario
        Get-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Mensagem' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $novos | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}
