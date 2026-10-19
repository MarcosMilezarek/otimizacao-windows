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
        @($vistos | Where-Object { $_ -in 'Read-Host', 'Read-Opcao', 'Get-Credential', 'Out-GridView', 'pause' -or $_ -like '*Menu*' }) | Should -BeNullOrEmpty
    }

    It 'Read-Host só dentro de Read-Opcao' {
        @($script:TodosComandos | Where-Object { $_ -eq 'Read-Host' }).Count | Should -Be 1
        $script:Chamadas['Read-Opcao'] | Should -Contain 'Read-Host'
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

Describe 'Preparação real na VM' {
    BeforeAll {
        $script:SidCliente = (Get-LocalUser -Name cliente).SID.Value
        $script:RaizReal = Join-Path $env:ProgramData ('OtimizacaoTesteMenu-' + [guid]::NewGuid())
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Fluxo' -Confirm:$false -ErrorAction SilentlyContinue
    }
    AfterAll {
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Fluxo' -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName 'Mensagem' -Confirm:$false -ErrorAction SilentlyContinue
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

        { Start-FluxoOtimizacao -PerfilOrigem (New-ArquivoPerfil) -UsuarioSid $script:SidCliente -Raiz $script:RaizReal } | Should -Throw '*fluxo em andamento*'

        Remove-TarefaOtimizacao -Nome 'Fluxo'
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
