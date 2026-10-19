<#
.SYNOPSIS
    Menu principal: escolhe o perfil do cliente e a ação, e conduz sozinho o fluxo completo, com as reinicializações.

.DESCRIPTION
    Sem parâmetros abre a janela do menu (exige administrador): perfis de cliente à esquerda, com Novo perfil
    (assistente em janela, src\Perfil.ps1), e à direita os itens do perfil escolhido, as ações e a saída dos scripts,
    que rodam em processo separado, um por vez:
      Fluxo completo: simula, mostra as etapas e pede uma única confirmação. Depois disso não há nenhuma pergunta:
        o fluxo segue por uma tarefa agendada que roda como SYSTEM a cada inicialização.
      Simular: executa com -WhatIf cada script com item no perfil, na ordem do fluxo. Nada é alterado.
      Só verificar agora: executa a Verificacao e mostra o resultado.
      Reverter: simula a reversão dos scripts com sessão não revertida, pede confirmação e reverte na ordem
        inversa (Limpeza, VisualEnergia, Inicializacao, Aplicativos, Manutencao).
    Com fluxo em andamento, o menu abre a janela de acompanhamento, com o botão Cancelar fluxo.

    Etapas do fluxo completo (script sem item aplicável no perfil é omitido):
      Reiniciar; Coleta antes 1 (espera alguém entrar no Windows); Reiniciar; Coleta antes 2 (espera logon); Reiniciar;
      Manutencao, Aplicativos, Inicializacao, VisualEnergia e Limpeza no boot, sem logon (com reinicialização pendente
      antes de um script, reinicia e tenta de novo, no máximo 2 vezes por script); Reiniciar; Coleta depois (espera
      logon); comparação antes e depois (HTML); Verificacao por último, com a mensagem aberta no Bloco de Notas na
      sessão do usuário conectado.
    As coletas esperam logon porque o tempo de boot (evento 100 de Diagnostics-Performance) só é gravado depois dele e
    os programas de inicialização do usuário só rodam com alguém conectado. "Alguém conectado" é qualquer sessão
    interativa ativa (console, Área de Trabalho Remota, AnyDesk), lida pela API WTS.

    Acompanhamento: a cada logon do usuário alvo durante o fluxo abre uma janela com as etapas, o status de cada uma e
    o fim do fluxo.log, atualizada sozinha (tarefa \Otimizacao\Acompanhar, parâmetro -Acompanhar; o console do
    PowerShell fica oculto e só a janela aparece). Fechá-la não afeta o fluxo. Abrir o Menu com um fluxo em andamento
    mostra a mesma janela.

    O fluxo para, remove a tarefa e mostra o motivo quando: um script termina com erro (código de saída diferente de 0,
    inclusive pré-checagem bloqueada e falha no ponto de restauração), a Manutencao registra achado (corrupção ou erro
    de disco, linhas "ATENÇÃO" do log), a Coleta não gera o arquivo ou a reinicialização pendente persiste.
    Uma etapa interrompida por queda de energia é executada de novo no boot seguinte (os scripts são idempotentes).

    Pasta do fluxo: %ProgramData%\Otimizacao\<Cliente>\<yyyyMMdd-HHmmss>-Fluxo com fluxo.json (estado), fluxo.log,
    perfil.psd1 (cópia congelada; UsuarioSid vazio vira o usuário conectado na hora do menu), src (cópia dos scripts,
    para o fluxo não depender do pendrive), saída de cada etapa, coletas, comparacao.html, verificacao.txt e
    mensagem.txt. Acesso restrito a SYSTEM e Administradores (usuários só leem), porque a tarefa executa como SYSTEM
    os scripts dessa pasta.

.PARAMETER Continuar
    Uso interno da tarefa agendada: pasta do fluxo a continuar. Não interativo.

.PARAMETER Acompanhar
    Uso interno da tarefa agendada de logon: pasta do fluxo a mostrar na janela de acompanhamento (somente leitura;
    o botão Cancelar fluxo só aparece se a janela estiver elevada).

.EXAMPLE
    .\Menu.ps1

.NOTES
    O que altera: cria a tarefa \Otimizacao\Fluxo (SYSTEM, na inicialização) e a \Otimizacao\Acompanhar (usuário alvo,
    no logon, abre a janela de acompanhamento), ambas removidas ao concluir, falhar ou cancelar,
    e por alguns segundos a tarefa \Otimizacao\Mensagem (usuário conectado), que abre a mensagem final. Reinicia o
    computador nas etapas do fluxo, com aviso de 60 s quando há alguém conectado. Os scripts chamados alteram o sistema
    conforme o perfil, cada um com o próprio ponto de restauração e backup.
    O que se perde: o uso do computador durante o fluxo (cerca de 1 h 30 a 2 h, com as três coletas).
    Reversão: botão Reverter do menu. Cancelar sem o menu: Unregister-ScheduledTask -TaskPath '\Otimizacao\' -TaskName Fluxo
    (e Acompanhar).
    A janela de acompanhamento acompanha as três coletas (ocupa pouco: lê um JSON a cada 10 s), igual em todas.
    Política de execução definida por GPO (MachinePolicy AllSigned) impede -ExecutionPolicy Bypass e o fluxo.
#>
[CmdletBinding(DefaultParameterSetName = 'Menu')]
param(
    [Parameter(ParameterSetName = 'Continuar', Mandatory)]
    [string]$Continuar,

    [Parameter(ParameterSetName = 'Acompanhar', Mandatory)]
    [string]$Acompanhar
)

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

$script:RaizFluxo = Join-Path $env:ProgramData 'Otimizacao'
$script:PowerShellExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:PastaTarefa = '\Otimizacao\'
$script:TarefaFluxo = 'Fluxo'
$script:TarefaMensagem = 'Mensagem'
$script:TarefaAcompanhar = 'Acompanhar'
$script:MaxReinicioPendente = 2
$script:AvisoReinicioSegundos = 60

# Ordem aprovada e itens que fazem cada script alterar algo (M5 a M7 são da Coleta; A3 não altera).
$script:Scripts = @(
    [pscustomobject]@{ Nome = 'Manutencao'; Prefixo = 'M'; Padrao = '^M[12348]$' }
    [pscustomobject]@{ Nome = 'Aplicativos'; Prefixo = 'A'; Padrao = '^A[124]$' }
    [pscustomobject]@{ Nome = 'Inicializacao'; Prefixo = 'I'; Padrao = '^I\d{1,2}$' }
    [pscustomobject]@{ Nome = 'VisualEnergia'; Prefixo = 'V'; Padrao = '^V\d{1,2}$' }
    [pscustomobject]@{ Nome = 'Limpeza'; Prefixo = 'L'; Padrao = '^L\d$' }
)

#region Plano e estado do fluxo

function Get-ScriptAplicavel {
    <# Nomes dos scripts, na ordem do fluxo, com ao menos um item que altera o sistema no perfil. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Perfil)
    @(foreach ($s in $script:Scripts) {
            if (@(Get-ItemPerfil -Perfil $Perfil -Prefixo $s.Prefixo | Where-Object { $_ -match $s.Padrao }).Count) { $s.Nome }
        })
}

function New-EtapaFluxo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria objeto em memória.')]
    param([string]$Tipo, [string]$Nome, [string]$Rotulo)
    [pscustomobject]@{ Tipo = $Tipo; Nome = $Nome; Rotulo = $Rotulo; Status = 'Pendente'; Tentativas = 0; Inicio = $null; Fim = $null; Detalhe = $null; Arquivo = $null }
}

function Get-PlanoFluxo {
    <# Etapas do fluxo completo para os scripts aplicáveis. #>
    param([Parameter(Mandatory)][string[]]$Scripts)
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar'
    New-EtapaFluxo -Tipo Coleta -Nome 'Coleta antes 1' -Rotulo 'antes1'
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar'
    New-EtapaFluxo -Tipo Coleta -Nome 'Coleta antes 2' -Rotulo 'antes2'
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar'
    foreach ($s in $Scripts) { New-EtapaFluxo -Tipo Script -Nome $s -Rotulo $s }
    New-EtapaFluxo -Tipo Reiniciar -Nome 'Reiniciar (final)'
    New-EtapaFluxo -Tipo Coleta -Nome 'Coleta depois' -Rotulo 'depois'
    New-EtapaFluxo -Tipo Comparar -Nome 'Comparação antes e depois'
    New-EtapaFluxo -Tipo Verificar -Nome 'Verificação final'
}

function Get-EstadoFluxo {
    param([Parameter(Mandatory)][string]$Pasta)
    [IO.File]::ReadAllText((Join-Path $Pasta 'fluxo.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Save-EstadoFluxo {
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)]$Estado)
    $Estado.Etapas = @($Estado.Etapas)
    [IO.File]::WriteAllText((Join-Path $Pasta 'fluxo.json'), (ConvertTo-Json -InputObject $Estado -Depth 5), (New-Object Text.UTF8Encoding $true))
}

function Write-RegistroFluxo {
    <# Linha com data no fluxo.log (diagnóstico do que a tarefa fez em cada boot). #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][string]$Texto)
    [IO.File]::AppendAllText((Join-Path $Pasta 'fluxo.log'), ('{0}  {1}{2}' -f (Get-Date).ToString('s'), $Texto, [Environment]::NewLine), (New-Object Text.UTF8Encoding $true))
}

function Get-FluxoEmAndamento {
    <# Pastas de fluxo com estado EmAndamento, de qualquer cliente. #>
    param([string]$Raiz = $script:RaizFluxo)
    foreach ($f in @(Get-ChildItem -Path (Join-Path $Raiz '*\*-Fluxo\fluxo.json') -ErrorAction SilentlyContinue)) {
        $e = Get-EstadoFluxo -Pasta $f.DirectoryName
        if ($e.Status -eq 'EmAndamento') { [pscustomobject]@{ Pasta = $f.DirectoryName; Estado = $e } }
    }
}

#endregion

#region Preparação do fluxo

function Set-AcessoRestrito {
    <# SYSTEM e Administradores com controle total, Usuários só leitura, sem herança. SIDs: independe do idioma. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada só depois da confirmação do menu.')]
    param([Parameter(Mandatory)][string]$Pasta)
    & "$env:windir\System32\icacls.exe" $Pasta /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls falhou ao restringir $Pasta (código $LASTEXITCODE)." }
}

function Copy-PerfilFluxo {
    <# Cópia congelada do perfil. Com UsuarioSid vazio, grava o SID recebido no lugar de UsuarioSid = ''. #>
    param([Parameter(Mandatory)][string]$Origem, [Parameter(Mandatory)][string]$Destino, [Parameter(Mandatory)][string]$UsuarioSid)
    if ($UsuarioSid -notmatch '^S-1-5-21(-\d+){4}$') { throw "SID de usuário fora do formato esperado: $UsuarioSid" }
    $texto = [IO.File]::ReadAllText($Origem, [Text.Encoding]::UTF8)
    $p = Import-PerfilCliente -Caminho $Origem
    if (-not $p.UsuarioSid) {
        $novo = [regex]::Replace($texto, "(?m)^(\s*UsuarioSid\s*=\s*)(''|`"`")", "`${1}'$UsuarioSid'")
        if ($novo -eq $texto) { throw "Perfil sem a linha UsuarioSid = '' para preencher. Informe UsuarioSid no perfil ($UsuarioSid)." }
        $texto = $novo
    }
    [IO.File]::WriteAllText($Destino, $texto, (New-Object Text.UTF8Encoding $true))
    $copia = Import-PerfilCliente -Caminho $Destino
    if ($copia.UsuarioSid -ne $UsuarioSid) { throw "A cópia do perfil tem UsuarioSid $($copia.UsuarioSid), diferente de $UsuarioSid." }
}

function Register-TarefaFluxo {
    <# Tarefa como SYSTEM a cada inicialização, sem limite de tempo (espera logon nas coletas), uma instância por vez. #>
    param([Parameter(Mandatory)][string]$Pasta)
    $menu = Join-Path $Pasta 'src\Menu.ps1'
    $sistema = ([Security.Principal.SecurityIdentifier]'S-1-5-18').Translate([Security.Principal.NTAccount]).Value
    $acao = New-ScheduledTaskAction -Execute $script:PowerShellExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Continuar "{1}"' -f $menu, $Pasta)
    $principal = New-ScheduledTaskPrincipal -UserId $sistema -LogonType ServiceAccount -RunLevel Highest
    $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaFluxo -Action $acao -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal $principal -Settings $cfg -Force -ErrorAction Stop | Out-Null
}

function Register-TarefaAcompanhar {
    <#
        Janela de acompanhamento a cada logon do usuário alvo (logon interativo, sem senha), elevada se ele for
        administrador. Console oculto: a janela é de WinForms.
    #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][string]$UsuarioSid)
    $usuario = ([Security.Principal.SecurityIdentifier]$UsuarioSid).Translate([Security.Principal.NTAccount]).Value
    $menu = Join-Path $Pasta 'src\Menu.ps1'
    $acao = New-ScheduledTaskAction -Execute $script:PowerShellExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Acompanhar "{1}"' -f $menu, $Pasta)
    $principal = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Highest
    $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaAcompanhar -Action $acao -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $usuario) `
        -Principal $principal -Settings $cfg -Force -ErrorAction Stop | Out-Null
}

function Remove-TarefaOtimizacao {
    <# Remove a tarefa indicada e, se ficar vazia, a pasta \Otimizacao\ do Agendador. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Remove só as tarefas criadas por este script.')]
    param([Parameter(Mandatory)][string]$Nome)
    Unregister-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $Nome -Confirm:$false -ErrorAction SilentlyContinue
    try {
        $servico = New-Object -ComObject Schedule.Service
        $servico.Connect()
        $pasta = $servico.GetFolder($script:PastaTarefa.TrimEnd('\'))
        if (-not $pasta.GetTasks(1).Count -and -not $pasta.GetFolders(0).Count) { $servico.GetFolder('\').DeleteFolder($pasta.Name, 0) }
    }
    catch { Write-Verbose "Pasta do Agendador mantida: $($_.Exception.Message)" }
}

function Remove-TarefasFluxo {
    <# Remove a janela de acompanhamento e, por último, a tarefa do fluxo (a pasta do Agendador some junto). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Remove só as tarefas criadas por este script.')]
    param()
    Remove-TarefaOtimizacao -Nome $script:TarefaAcompanhar
    Remove-TarefaOtimizacao -Nome $script:TarefaFluxo
}

function Start-FluxoOtimizacao {
    <#
        Cria a pasta do fluxo (acesso restrito, cópia de src e do perfil), grava o estado e registra a tarefa.
        Não reinicia: o chamador executa Invoke-FluxoOtimizacao em seguida. Retorna a pasta do fluxo.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada só depois da confirmação do menu.')]
    param(
        [Parameter(Mandatory)][string]$PerfilOrigem,
        [Parameter(Mandatory)][string]$UsuarioSid,
        [int]$AguardarUptimeMinutos = 10,
        [int]$AmostraSegundos = 300,
        [string]$Raiz = $script:RaizFluxo
    )
    $p = Import-PerfilCliente -Caminho $PerfilOrigem
    $scripts = Get-ScriptAplicavel -Perfil $p
    if (-not $scripts.Count) { throw 'Nenhum item que altere o sistema no perfil.' }
    if (@(Get-FluxoEmAndamento -Raiz $Raiz).Count) { throw 'Já existe um fluxo em andamento. Cancele-o antes de iniciar outro.' }

    $pasta = Join-Path (Join-Path $Raiz $p.Cliente) ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-Fluxo')
    New-Item -ItemType Directory -Path $pasta -Force | Out-Null
    Set-AcessoRestrito -Pasta $pasta
    $src = New-Item -ItemType Directory -Path (Join-Path $pasta 'src') -Force
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Include '*.ps1', '*.psm1' -Destination $src.FullName -ErrorAction Stop
    $perfilFluxo = Join-Path $pasta 'perfil.psd1'
    Copy-PerfilFluxo -Origem $PerfilOrigem -Destino $perfilFluxo -UsuarioSid $UsuarioSid

    $estado = [pscustomobject]@{
        Cliente               = $p.Cliente
        Computador            = $env:COMPUTERNAME
        PerfilOrigem          = (Resolve-Path -LiteralPath $PerfilOrigem).Path
        Perfil                = $perfilFluxo
        UsuarioSid            = $UsuarioSid
        IniciadoPor           = "$env:USERDOMAIN\$env:USERNAME"
        Inicio                = (Get-Date).ToString('s')
        Fim                   = $null
        Status                = 'EmAndamento'
        Motivo                = $null
        MensagemExibida       = $false
        Indice                = 0
        Reinicializacoes      = 0
        AguardarUptimeMinutos = $AguardarUptimeMinutos
        AmostraSegundos       = $AmostraSegundos
        Etapas                = @(Get-PlanoFluxo -Scripts $scripts)
    }
    Save-EstadoFluxo -Pasta $pasta -Estado $estado
    Write-RegistroFluxo -Pasta $pasta -Texto "Fluxo criado por $($estado.IniciadoPor) com $($estado.Etapas.Count) etapas: $($scripts -join ', ')."
    Register-TarefaFluxo -Pasta $pasta
    # A janela é conforto: se não registrar, o fluxo segue e o motivo fica no log.
    try { Register-TarefaAcompanhar -Pasta $pasta -UsuarioSid $UsuarioSid }
    catch { Write-RegistroFluxo -Pasta $pasta -Texto "Janela de acompanhamento não registrada: $($_.Exception.Message)" }
    $pasta
}

#endregion

#region Execução das etapas (tarefa agendada, sem interação)

function Get-SessaoInterativa {
    <#
        Sessões com usuário, pela API WTS: Id, Estado (0 = ativa, 4 = desconectada) e Usuario (DOMINIO\conta).
        Win32_ComputerSystem.UserName só enxerga o console: sessões de Área de Trabalho Remota e de AnyDesk voltam vazias.
    #>
    if (-not ('OtimizacaoWts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class OtimizacaoWts
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SessionInfo { public int SessionId; public IntPtr WinStationName; public int State; }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr info, out int count);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr memory);

    private static string Consultar(int id, int classe)
    {
        IntPtr buffer; int bytes;
        if (!WTSQuerySessionInformationW(IntPtr.Zero, id, classe, out buffer, out bytes)) return "";
        try { return Marshal.PtrToStringUni(buffer) ?? ""; } finally { WTSFreeMemory(buffer); }
    }

    // Uma linha por sessão com usuário: Id|Estado|Dominio|Usuario (WTSUserName = 5, WTSDomainName = 7).
    public static string[] Listar()
    {
        IntPtr info; int count;
        if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out info, out count))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        var lista = new List<string>();
        try
        {
            int tamanho = Marshal.SizeOf(typeof(SessionInfo));
            for (int i = 0; i < count; i++)
            {
                var s = (SessionInfo)Marshal.PtrToStructure(new IntPtr(info.ToInt64() + (long)i * tamanho), typeof(SessionInfo));
                string usuario = Consultar(s.SessionId, 5);
                if (usuario.Length == 0) continue;
                lista.Add(s.SessionId + "|" + s.State + "|" + Consultar(s.SessionId, 7) + "|" + usuario);
            }
        }
        finally { WTSFreeMemory(info); }
        return lista.ToArray();
    }
}
'@
    }
    foreach ($linha in [OtimizacaoWts]::Listar()) {
        $p = $linha.Split('|')
        [pscustomobject]@{ Id = [int]$p[0]; Estado = [int]$p[1]; Usuario = $(if ($p[2]) { "$($p[2])\$($p[3])" } else { $p[3] }) }
    }
}

function Get-UsuarioConectado {
    <# Conta com sessão interativa ativa (console, Área de Trabalho Remota ou AnyDesk), ou vazio. Sessão 0 não conta. #>
    [string](@(Get-SessaoInterativa | Where-Object { $_.Estado -eq 0 -and $_.Id -ne 0 } | Sort-Object -Property Id | Select-Object -First 1 | ForEach-Object { $_.Usuario }))
}

function Wait-Logon {
    <# Espera alguém entrar no Windows. Retorna $false se o fluxo for cancelado durante a espera. #>
    param([Parameter(Mandatory)][string]$Pasta, [int]$IntervaloSegundos = 15)
    while (-not (Get-UsuarioConectado)) {
        if ((Get-EstadoFluxo -Pasta $Pasta).Status -ne 'EmAndamento') { return $false }
        Start-Sleep -Seconds $IntervaloSegundos
    }
    $true
}

function Restart-Fluxo {
    <# Reinicia com aviso quando há alguém conectado. shutdown.exe existe em todas as edições. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Etapa do fluxo confirmado no menu.')]
    param([Parameter(Mandatory)][string]$Pasta)
    $segundos = if (Get-UsuarioConectado) { $script:AvisoReinicioSegundos } else { 0 }
    Write-RegistroFluxo -Pasta $Pasta -Texto "Reiniciando em $segundos s."
    # /d p:4:1 = planejado, manutenção de aplicativo (motivo registrado no log de eventos).
    & "$env:windir\System32\shutdown.exe" /r /t $segundos /d p:4:1 /c 'Otimização em andamento: o computador vai reiniciar. Salve seus arquivos.' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe falhou (código $LASTEXITCODE)." }
}

function Invoke-ProcessoEtapa {
    <# Executa um .ps1 num processo PowerShell 5.1 separado, grava a saída (UTF-8) e retorna o código de saída. #>
    param([Parameter(Mandatory)][string]$Arquivo, [string[]]$Argumentos = @(), [Parameter(Mandatory)][string]$Saida)
    $ErrorActionPreference = 'Continue'
    $linhas = @(& $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Arquivo @Argumentos 2>&1 | ForEach-Object { "$_" })
    $codigo = $LASTEXITCODE
    [IO.File]::WriteAllLines($Saida, [string[]]$linhas, (New-Object Text.UTF8Encoding $true))
    $codigo
}

function Get-FimSaida {
    <# Últimas linhas não vazias de uma saída de etapa, para o motivo da mensagem. #>
    param([string]$Arquivo, [int]$Linhas = 6)
    if (-not $Arquivo -or -not (Test-Path -LiteralPath $Arquivo)) { return '' }
    (@([IO.File]::ReadAllLines($Arquivo, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() }) | Select-Object -Last $Linhas) -join [Environment]::NewLine
}

function Get-AchadoManutencao {
    <# Achados (linhas Info com "ATENÇÃO:") da sessão de Manutencao mais recente criada a partir de Desde. #>
    param([Parameter(Mandatory)][string]$Cliente, [Parameter(Mandatory)][datetime]$Desde, [string]$Raiz = $script:RaizFluxo)
    $sessao = Get-ChildItem -LiteralPath (Join-Path $Raiz $Cliente) -Directory -Filter '*-Manutencao' -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -ge $Desde.AddSeconds(-5) } | Sort-Object -Property Name | Select-Object -Last 1
    if (-not $sessao) { return @() }
    $log = Join-Path $sessao.FullName 'log.csv'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @(Import-Csv -LiteralPath $log -Encoding UTF8 | Where-Object { $_.Resultado -eq 'Info' -and $_.Detalhe -like 'ATENÇÃO:*' } |
            ForEach-Object { "[$($_.Item)] $($_.Alvo): $($_.Detalhe.Substring(9).Trim())" })
}

function Invoke-EtapaFluxo {
    <#
        Executa uma etapa e devolve a decisão: Seguir (próxima etapa), Reiniciar (o boot seguinte continua) ou Parar (com
        Motivo). Atualiza Status, Detalhe e Arquivo da etapa; o chamador grava o estado.
    #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)]$Etapa, [Parameter(Mandatory)][string]$Pasta)
    $numero = [int]$Estado.Indice + 1
    $src = Join-Path $Pasta 'src'
    $saida = Join-Path $Pasta ('etapa-{0:D2}-{1}.txt' -f $numero, ($Etapa.Nome -replace '[^\w]+', '-').Trim('-'))
    $decisao = { param($Acao, $Motivo) [pscustomobject]@{ Acao = $Acao; Motivo = $Motivo } }

    switch ($Etapa.Tipo) {
        'Reiniciar' {
            $Etapa.Status = 'OK'
            return & $decisao 'Reiniciar' $null
        }
        'Coleta' {
            if (-not (Wait-Logon -Pasta $Pasta)) { return & $decisao 'Parar' 'Fluxo cancelado.' }
            $destino = Join-Path $Pasta "coleta-$($Etapa.Rotulo)"
            New-Item -ItemType Directory -Path $destino -Force | Out-Null
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src 'Coleta.ps1') -Saida $saida -Argumentos @(
                '-UsuarioSid', $Estado.UsuarioSid, '-AguardarUptimeMinutos', [string]$Estado.AguardarUptimeMinutos,
                '-AmostraSegundos', [string]$Estado.AmostraSegundos, '-PastaSaida', $destino)
            $json = Get-ChildItem -LiteralPath $destino -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime | Select-Object -Last 1
            if (-not $json) { $Etapa.Status = 'Falha'; $Etapa.Arquivo = $saida; return & $decisao 'Parar' "A $($Etapa.Nome) não gerou o arquivo de resultado (código $codigo)." }
            $Etapa.Arquivo = $json.FullName
            $Etapa.Status = 'OK'
            return & $decisao 'Seguir' $null
        }
        'Script' {
            if ((Test-ReinicializacaoPendente).PSObject.Properties.Value -contains $true) {
                if ([int]$Etapa.Tentativas -ge $script:MaxReinicioPendente) {
                    $Etapa.Status = 'Falha'
                    return & $decisao 'Parar' "Reinicialização pendente continua depois de $($script:MaxReinicioPendente) reinicializações (Windows Update ou instalação em andamento)."
                }
                $Etapa.Tentativas = [int]$Etapa.Tentativas + 1
                $Etapa.Detalhe = 'Reinicialização pendente: reiniciando antes do script.'
                return & $decisao 'Reiniciar' $null
            }
            $inicio = Get-Date
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src "$($Etapa.Nome).ps1") -Argumentos @('-Perfil', $Estado.Perfil) -Saida $saida
            $Etapa.Arquivo = $saida
            if ($codigo -ne 0) { $Etapa.Status = 'Falha'; return & $decisao 'Parar' "$($Etapa.Nome) terminou com erro (código $codigo)." }
            if ($Etapa.Nome -eq 'Manutencao') {
                $achados = @(Get-AchadoManutencao -Cliente $Estado.Cliente -Desde $inicio)
                if ($achados.Count) {
                    $Etapa.Status = 'Falha'
                    return & $decisao 'Parar' ("A Manutencao encontrou problema que precisa ser resolvido antes de otimizar: " + ($achados -join ' | '))
                }
            }
            $Etapa.Status = 'OK'
            return & $decisao 'Seguir' $null
        }
        'Comparar' {
            $coletas = @(@($Estado.Etapas) | Where-Object { $_.Tipo -eq 'Coleta' })
            $antes = @($coletas | Where-Object { $_.Rotulo -like 'antes*' } | ForEach-Object { $_.Arquivo })
            $depois = ($coletas | Where-Object { $_.Rotulo -eq 'depois' }).Arquivo
            $html = Join-Path $Pasta 'comparacao.html'
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src 'Coleta.ps1') -Saida $saida -Argumentos @('-Comparar', '-Antes', ($antes -join ','), '-Depois', $depois, '-SaidaHtml', $html)
            # Comparação é só leitura: sem ela a verificação ainda vale, então o fluxo segue.
            if (Test-Path -LiteralPath $html) { $Etapa.Arquivo = $html; $Etapa.Status = 'OK' }
            else { $Etapa.Status = 'Falha'; $Etapa.Detalhe = "Comparação não gerada (código $codigo). Ver $saida." }
            return & $decisao 'Seguir' $null
        }
        'Verificar' {
            $relatorio = Join-Path $Pasta 'verificacao.txt'
            $codigo = Invoke-ProcessoEtapa -Arquivo (Join-Path $src 'Verificacao.ps1') -Argumentos @('-Perfil', $Estado.Perfil, '-Relatorio', $relatorio) -Saida $saida
            if (Test-Path -LiteralPath $relatorio) { $Etapa.Arquivo = $relatorio; $Etapa.Status = 'OK' }
            else { $Etapa.Status = 'Falha'; $Etapa.Detalhe = "Verificação não concluída (código $codigo). Ver $saida." }
            return & $decisao 'Seguir' $null
        }
        default { throw "Tipo de etapa desconhecido: $($Etapa.Tipo)." }
    }
}

function Get-TextoMensagem {
    <# Mensagem final em linguagem simples: resultado da verificação (concluído) ou motivo da interrupção. #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)][string]$Pasta)
    $etapas = @($Estado.Etapas)
    $l = New-Object System.Collections.Generic.List[string]
    $quando = '{0} a {1}' -f ([datetime]$Estado.Inicio).ToString('dd/MM/yyyy HH:mm'), (Get-Date).ToString('dd/MM/yyyy HH:mm')
    if ($Estado.Status -eq 'Concluido') {
        $l.Add("Otimização concluída no computador $($Estado.Computador) (cliente $($Estado.Cliente)).")
        $l.Add("Período: $quando. Reinicializações: $($Estado.Reinicializacoes).")
        $l.Add('')
        $verificacao = ($etapas | Where-Object { $_.Tipo -eq 'Verificar' }).Arquivo
        if ($verificacao -and (Test-Path -LiteralPath $verificacao)) { foreach ($x in [IO.File]::ReadAllLines($verificacao, [Text.Encoding]::UTF8)) { $l.Add($x) } }
        else { $l.Add('A verificação final não foi concluída. ' + ($etapas | Where-Object { $_.Tipo -eq 'Verificar' }).Detalhe) }
        $l.Add('')
        $comparar = $etapas | Where-Object { $_.Tipo -eq 'Comparar' }
        if ($comparar.Status -eq 'OK') { $l.Add("Desempenho antes e depois (abrir no navegador): $($comparar.Arquivo)") }
        else { $l.Add("Comparação de desempenho não gerada. $($comparar.Detalhe)") }
    }
    else {
        $atual = $etapas[[int]$Estado.Indice]
        $l.Add("A otimização foi interrompida no computador $($Estado.Computador) (cliente $($Estado.Cliente)).")
        $l.Add("Etapa $([int]$Estado.Indice + 1) de $($etapas.Count): $($atual.Nome).")
        $l.Add("Motivo: $($Estado.Motivo)")
        $l.Add("Período: $quando. Reinicializações: $($Estado.Reinicializacoes).")
        $l.Add('')
        $feitas = @($etapas | Where-Object { $_.Status -eq 'OK' -and $_.Tipo -eq 'Script' } | ForEach-Object { $_.Nome })
        $l.Add($(if ($feitas.Count) { "Scripts concluídos antes da interrupção: $($feitas -join ', '). O que eles aplicaram continua aplicado." } else { 'Nenhum script de otimização chegou a ser concluído.' }))
        $l.Add('Nada mais foi executado depois da interrupção.')
        $fim = Get-FimSaida -Arquivo $atual.Arquivo
        if ($fim) { $l.Add(''); $l.Add('Final da saída da etapa:'); foreach ($x in $fim -split [Environment]::NewLine) { $l.Add("  $x") } }
        $l.Add('')
        $l.Add('Para desfazer o que foi aplicado: abra o Menu como administrador e escolha Reverter.')
    }
    $l.Add("Arquivos do fluxo: $Pasta")
    $l.ToArray()
}

function Show-MensagemUsuario {
    <#
        Abre a mensagem no Bloco de Notas na sessão do usuário conectado: a tarefa roda como SYSTEM (sessão 0, sem tela),
        então registra uma tarefa temporária no nome do usuário (logon interativo, sem senha), inicia e remove.
    #>
    param([Parameter(Mandatory)][string]$Arquivo, [Parameter(Mandatory)][string]$Pasta)
    if (-not (Wait-Logon -Pasta $Pasta)) { return }
    $usuario = Get-UsuarioConectado
    $acao = New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\notepad.exe') -Argument "`"$Arquivo`""
    $principal = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Limited
    $cfg = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaMensagem -Action $acao -Principal $principal -Settings $cfg -Force -ErrorAction Stop | Out-Null
    try {
        Start-ScheduledTask -TaskPath $script:PastaTarefa -TaskName $script:TarefaMensagem -ErrorAction Stop
        $limite = (Get-Date).AddSeconds(30)
        do { Start-Sleep -Seconds 2; $info = Get-ScheduledTaskInfo -TaskPath $script:PastaTarefa -TaskName $script:TarefaMensagem }
        while ($info.LastRunTime -lt (Get-Date).AddMinutes(-1) -and (Get-Date) -lt $limite)
        Write-RegistroFluxo -Pasta $Pasta -Texto "Mensagem aberta para $usuario (última execução $($info.LastRunTime), resultado $($info.LastTaskResult))."
    }
    finally { Remove-TarefaOtimizacao -Nome $script:TarefaMensagem }
}

function Complete-Fluxo {
    <#
        Encerra o fluxo: grava estado e mensagem, abre a mensagem para o usuário conectado (espera logon) e por último
        remove a tarefa. Se o PC reiniciar antes de alguém entrar, a tarefa ainda existe e o boot seguinte mostra a mensagem.
    #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][ValidateSet('Concluido', 'Interrompido')][string]$Status, [string]$Motivo)
    $Estado.Status = $Status
    $Estado.Motivo = $Motivo
    $Estado.Fim = (Get-Date).ToString('s')
    Save-EstadoFluxo -Pasta $Pasta -Estado $Estado
    Write-RegistroFluxo -Pasta $Pasta -Texto "Fluxo $Status. $Motivo"
    [IO.File]::WriteAllLines((Join-Path $Pasta 'mensagem.txt'), [string[]](Get-TextoMensagem -Estado $Estado -Pasta $Pasta), (New-Object Text.UTF8Encoding $true))
    Show-MensagemPendente -Estado $Estado -Pasta $Pasta
}

function Show-MensagemPendente {
    <# Abre mensagem.txt se ainda não foi aberta, marca no estado e remove a tarefa do fluxo (última ação). #>
    param([Parameter(Mandatory)]$Estado, [Parameter(Mandatory)][string]$Pasta)
    if (-not $Estado.MensagemExibida) {
        Show-MensagemUsuario -Arquivo (Join-Path $Pasta 'mensagem.txt') -Pasta $Pasta
        $Estado.MensagemExibida = $true
        Save-EstadoFluxo -Pasta $Pasta -Estado $Estado
    }
    Remove-TarefasFluxo
}

function Invoke-FluxoOtimizacao {
    <# Executa as etapas a partir da atual até concluir, reiniciar ou parar. Chamado pela tarefa a cada boot. #>
    param([Parameter(Mandatory)][string]$Pasta)
    # Saída UTF-8 entre este processo e os filhos (acentos nas saídas gravadas). Sem console, segue com o padrão.
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { Write-Verbose 'Console sem codificação ajustável.' }
    $estado = Get-EstadoFluxo -Pasta $Pasta
    if ($estado.Status -in 'Concluido', 'Interrompido') { return Show-MensagemPendente -Estado $estado -Pasta $Pasta }
    if ($estado.Status -ne 'EmAndamento') { Remove-TarefasFluxo; return }
    Write-RegistroFluxo -Pasta $Pasta -Texto "Retomando na etapa $([int]$estado.Indice + 1) como $env:USERDOMAIN\$env:USERNAME."
    try {
        while ([int]$estado.Indice -lt @($estado.Etapas).Count) {
            # Relê o estado: o menu pode ter cancelado o fluxo enquanto a etapa anterior rodava.
            $estado = Get-EstadoFluxo -Pasta $Pasta
            if ($estado.Status -ne 'EmAndamento') { Write-RegistroFluxo -Pasta $Pasta -Texto "Fluxo $($estado.Status): parado."; Remove-TarefasFluxo; return }
            $etapa = @($estado.Etapas)[[int]$estado.Indice]
            $etapa.Status = 'Executando'
            $etapa.Inicio = (Get-Date).ToString('s')
            Save-EstadoFluxo -Pasta $Pasta -Estado $estado
            Write-RegistroFluxo -Pasta $Pasta -Texto "Etapa $([int]$estado.Indice + 1): $($etapa.Nome)."

            $r = Invoke-EtapaFluxo -Estado $estado -Etapa $etapa -Pasta $Pasta
            $etapa.Fim = (Get-Date).ToString('s')
            switch ($r.Acao) {
                'Seguir' { $estado.Indice = [int]$estado.Indice + 1; Save-EstadoFluxo -Pasta $Pasta -Estado $estado }
                'Reiniciar' {
                    if ($etapa.Status -eq 'OK') { $estado.Indice = [int]$estado.Indice + 1 }
                    $estado.Reinicializacoes = [int]$estado.Reinicializacoes + 1
                    Save-EstadoFluxo -Pasta $Pasta -Estado $estado
                    Restart-Fluxo -Pasta $Pasta
                    return
                }
                'Parar' { return Complete-Fluxo -Estado $estado -Pasta $Pasta -Status Interrompido -Motivo $r.Motivo }
            }
        }
        Complete-Fluxo -Estado $estado -Pasta $Pasta -Status Concluido
    }
    catch {
        Write-RegistroFluxo -Pasta $Pasta -Texto "Erro: $($_.Exception.Message)"
        # Erro ao encerrar (mensagem): o estado já está gravado e o próximo boot tenta mostrar a mensagem de novo.
        if ($estado.Status -eq 'EmAndamento') { Complete-Fluxo -Estado $estado -Pasta $Pasta -Status Interrompido -Motivo "Erro inesperado no fluxo: $($_.Exception.Message)" }
    }
}

#endregion

#region Menu (janelas)

function Get-SessaoPendente {
    <# Script tem sessão de aplicação ainda não revertida (mesmo critério do -Revert). #>
    param([Parameter(Mandatory)][string]$Cliente, [Parameter(Mandatory)][string]$Script, [string]$Raiz = $script:RaizFluxo)
    [bool]@(Get-ChildItem -LiteralPath (Join-Path $Raiz $Cliente) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-$Script" -and -not (Test-Path -LiteralPath (Join-Path $_.FullName 'revertido.txt')) }).Count
}

function Get-PendenteReversao {
    <# Scripts com sessão não revertida, na ordem da reversão (inversa à do fluxo). #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Cliente, [string]$Raiz = $script:RaizFluxo)
    $ordem = @($script:Scripts | ForEach-Object { $_.Nome })
    [array]::Reverse($ordem)
    @($ordem | Where-Object { Get-SessaoPendente -Cliente $Cliente -Script $_ -Raiz $Raiz })
}

function Resolve-UsuarioFluxo {
    <# SID do usuário alvo para o fluxo: o do perfil ou, vazio, o do usuário conectado agora. #>
    param([Parameter(Mandatory)]$Perfil)
    $alvo = Get-UsuarioAlvo -Sid $Perfil.UsuarioSid
    $nome = try { ([Security.Principal.SecurityIdentifier]$alvo.Sid).Translate([Security.Principal.NTAccount]).Value } catch { $alvo.Sid }
    [pscustomobject]@{ Sid = $alvo.Sid; Nome = $nome; DoPerfil = [bool]$Perfil.UsuarioSid }
}

function Get-CondicaoFluxo {
    <# O que precisa estar certo antes de simular o fluxo: scripts aplicáveis, avisos e bloqueios da pré-checagem e o usuário alvo. Erro vazio = pode seguir. #>
    param([Parameter(Mandatory)]$Perfil)
    $r = [pscustomobject]@{ Scripts = @(Get-ScriptAplicavel -Perfil $Perfil); Avisos = @(); Bloqueios = @(); Usuario = $null; Erro = $null }
    if (-not $r.Scripts.Count) { $r.Erro = 'Nenhum item que altere o sistema no perfil.'; return $r }
    $pre = Test-PreCondicao -PermitirReinicializacaoPendente
    $r.Avisos = @($pre.Avisos)
    $r.Bloqueios = @($pre.Bloqueios)
    if ($r.Bloqueios.Count) { $r.Erro = 'Resolva os bloqueios e tente de novo. Nada foi alterado.'; return $r }
    try { $r.Usuario = Resolve-UsuarioFluxo -Perfil $Perfil }
    catch { $r.Erro = "Usuário alvo: $($_.Exception.Message) Preencha UsuarioSid no perfil." }
    $r
}

function Stop-FluxoMenu {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Chamada só depois da confirmação na janela.')]
    param([Parameter(Mandatory)]$Fluxo)
    $Fluxo.Estado.Status = 'Cancelado'
    $Fluxo.Estado.Fim = (Get-Date).ToString('s')
    Save-EstadoFluxo -Pasta $Fluxo.Pasta -Estado $Fluxo.Estado
    Write-RegistroFluxo -Pasta $Fluxo.Pasta -Texto "Cancelado no menu por $env:USERDOMAIN\$env:USERNAME."
    Remove-TarefasFluxo
}

function Get-PastaPerfil {
    <# Pastas de perfis: os gerados pelo Novo perfil (na máquina, nunca no repositório) e perfis\ do projeto. #>
    Join-Path $script:RaizFluxo 'perfis'
    Join-Path (Split-Path -Parent $PSScriptRoot) 'perfis'
}

function Get-ArquivoPerfil {
    <# Perfis .psd1 das pastas de perfis, sem o exemplo do projeto, por nome. #>
    @(foreach ($p in Get-PastaPerfil) { Get-ChildItem -LiteralPath $p -Filter '*.psd1' -File -ErrorAction SilentlyContinue }) |
        Where-Object { $_.Name -ne 'exemplo.psd1' } | Sort-Object -Property Name
}

function Get-LinhaAcompanhamento {
    <# Linhas da tabela de etapas: Numero, Nome, Status, Inicio e Fim (HH:mm:ss), Detalhe e Atual (etapa em execução). #>
    param([Parameter(Mandatory)]$Estado)
    $etapas = @($Estado.Etapas)
    $hora = { param($v) if ($v) { ([datetime]$v).ToString('HH:mm:ss') } else { '' } }
    for ($i = 0; $i -lt $etapas.Count; $i++) {
        $e = $etapas[$i]
        [pscustomobject]@{
            Numero = $i + 1; Nome = $e.Nome; Status = $e.Status; Inicio = (& $hora $e.Inicio); Fim = (& $hora $e.Fim); Detalhe = [string]$e.Detalhe
            Atual = ($Estado.Status -eq 'EmAndamento' -and $i -eq [int]$Estado.Indice)
        }
    }
}

function Get-CabecalhoAcompanhamento {
    <# Textos do topo da janela de acompanhamento: Titulo, Info, Atual, Dica, Concluidas e Total. #>
    param([Parameter(Mandatory)]$Estado)
    $etapas = @($Estado.Etapas)
    $atual = [int]$Estado.Indice
    $nome = @{ Concluido = 'concluído'; Interrompido = 'interrompido'; Cancelado = 'cancelado' }
    $r = [pscustomobject]@{
        Titulo     = "Fluxo $(if ($nome.ContainsKey([string]$Estado.Status)) { $nome[[string]$Estado.Status] } else { $Estado.Status }): cliente $($Estado.Cliente)"
        Info       = "Computador $($Estado.Computador), iniciado em $(([datetime]$Estado.Inicio).ToString('dd/MM/yyyy HH:mm')), reinicializações $($Estado.Reinicializacoes)."
        Atual      = ''
        Dica       = ''
        Concluidas = @($etapas | Where-Object { $_.Status -eq 'OK' }).Count
        Total      = $etapas.Count
    }
    if ($Estado.Status -eq 'EmAndamento' -and $atual -lt $etapas.Count) {
        $r.Titulo = "Fluxo em andamento: cliente $($Estado.Cliente)"
        $r.Atual = "Etapa $($atual + 1) de $($etapas.Count): $($etapas[$atual].Nome)."
        $r.Dica = if ($etapas[$atual].Tipo -eq 'Coleta') {
            "A coleta espera $($Estado.AguardarUptimeMinutos) min depois da inicialização e mede por $($Estado.AmostraSegundos) s. Deixe o computador parado até ele reiniciar sozinho."
        }
        else { 'A otimização roda sozinha. Não é preciso fazer nada; o computador reinicia quando precisar.' }
    }
    elseif ($Estado.Status -ne 'EmAndamento') {
        $r.Atual = if ($Estado.Motivo) { "Motivo: $($Estado.Motivo)" } else { '' }
        $r.Dica = if ($Estado.Status -in 'Concluido', 'Interrompido') { 'O resultado abre no Bloco de Notas e fica em mensagem.txt na pasta do fluxo.' } else { 'Nada mais será executado. O que já foi aplicado continua; para desfazer, use Reverter.' }
    }
    $r
}

function Get-FimLogFluxo {
    param([Parameter(Mandatory)][string]$Pasta, [int]$Linhas = 6)
    $log = Join-Path $Pasta 'fluxo.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @([IO.File]::ReadAllLines($log, [Text.Encoding]::UTF8) | Select-Object -Last $Linhas)
}

function Join-ArgumentoProcesso {
    <# Linha de comando do processo: argumento com espaço ou vazio entre aspas (caminhos não contêm aspas). #>
    [OutputType([string])]
    param([string[]]$Argumentos = @())
    (@($Argumentos) | ForEach-Object { if ($_ -eq '' -or $_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

function Get-CodificacaoConsole {
    <#
        Codificação da saída de um processo filho sem janela: ele ganha um console novo, que usa a página OEM do sistema
        (850 num Windows pt-BR, 65001 com a opção UTF-8 ligada). A cultura do usuário não serve: no host ela dizia 850 com o sistema em 65001.
    #>
    if (-not ('Otimizacao.PaginaCodigo' -as [type])) {
        Add-Type -Namespace Otimizacao -Name PaginaCodigo -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint GetOEMCP();'
    }
    $cp = [int][Otimizacao.PaginaCodigo]::GetOEMCP()
    if ($cp -eq 65001) { New-Object Text.UTF8Encoding $false } else { [Text.Encoding]::GetEncoding($cp) }
}

function Start-ProcessoScript {
    <# Inicia um .ps1 num PowerShell 5.1 separado, sem janela, com a saída e os erros lidos pela janela do Menu (Read-SaidaProcesso). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só inicia o processo; o que ele altera é decidido pelos argumentos escolhidos na janela.')]
    param([Parameter(Mandatory)][string]$Arquivo, [string[]]$Argumentos = @())
    $psi = New-Object Diagnostics.ProcessStartInfo $script:PowerShellExe
    $psi.Arguments = Join-ArgumentoProcesso -Argumentos (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Arquivo) + $Argumentos)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $psi.StandardErrorEncoding = Get-CodificacaoConsole
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Processo = $p; Leituras = @{ Saida = $p.StandardOutput.ReadLineAsync(); Erro = $p.StandardError.ReadLineAsync() } }
}

function Read-SaidaProcesso {
    <# Linhas já disponíveis do processo, sem bloquear (chamada pelo temporizador da janela). Terminou = saída esgotada e processo encerrado. #>
    param([Parameter(Mandatory)]$Execucao)
    $linhas = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'Saida', 'Erro') {
        $leitor = if ($k -eq 'Saida') { $Execucao.Processo.StandardOutput } else { $Execucao.Processo.StandardError }
        while ($Execucao.Leituras[$k] -and $Execucao.Leituras[$k].IsCompleted) {
            $l = if ($Execucao.Leituras[$k].IsFaulted) { $null } else { $Execucao.Leituras[$k].Result }
            if ($null -eq $l) { $Execucao.Leituras[$k] = $null }
            else { $linhas.Add($l); $Execucao.Leituras[$k] = $leitor.ReadLineAsync() }
        }
    }
    $terminou = -not $Execucao.Leituras['Saida'] -and -not $Execucao.Leituras['Erro'] -and $Execucao.Processo.HasExited
    [pscustomobject]@{ Linhas = $linhas.ToArray(); Terminou = $terminou; Codigo = $(if ($terminou) { $Execucao.Processo.ExitCode }) }
}

function Initialize-Interface {
    <# WinForms, estilos visuais, DPI, cores e fontes. Só nas janelas: o fluxo no boot (SYSTEM, sem tela) não carrega nada disso. #>
    if ($script:CorJanela) { return }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('Otimizacao.Dpi' -as [type])) { Add-Type -Namespace Otimizacao -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' }
    [void][Otimizacao.Dpi]::SetProcessDPIAware()
    [Windows.Forms.Application]::EnableVisualStyles()
    $script:CorJanela = @{
        Fundo = [Drawing.Color]::FromArgb(243, 243, 243); Branco = [Drawing.Color]::White; Topo = [Drawing.Color]::FromArgb(32, 32, 32)
        Acento = [Drawing.Color]::FromArgb(0, 95, 184); Texto = [Drawing.Color]::Black; Texto2 = [Drawing.Color]::FromArgb(96, 96, 96)
        Borda = [Drawing.Color]::FromArgb(210, 210, 210); OK = [Drawing.Color]::FromArgb(16, 124, 16); Execucao = [Drawing.Color]::FromArgb(157, 93, 0)
        ExecucaoFundo = [Drawing.Color]::FromArgb(255, 244, 206); Falha = [Drawing.Color]::FromArgb(196, 43, 28); Pendente = [Drawing.Color]::FromArgb(130, 130, 130)
        Console = [Drawing.Color]::FromArgb(30, 30, 30); ConsoleTexto = [Drawing.Color]::FromArgb(220, 220, 220)
    }
    $script:FonteJanela = @{
        Normal = New-Object Drawing.Font('Segoe UI', 10); Negrito = New-Object Drawing.Font('Segoe UI Semibold', 10)
        Titulo = New-Object Drawing.Font('Segoe UI Semibold', 15); Sub = New-Object Drawing.Font('Segoe UI Semibold', 12)
        Mono = New-Object Drawing.Font('Consolas', 9.5); Pequena = New-Object Drawing.Font('Segoe UI', 8.5); Lista = New-Object Drawing.Font('Segoe UI', 11)
    }
}

function Set-TamanhoJanela {
    <# Tamanho e mínimo pedidos, limitados à área útil da tela: em 1024x768 (VM) o rodapé com os botões ficava fora. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só ajusta o tamanho da janela em memória.')]
    param([Parameter(Mandatory)]$Janela, [int]$Largura, [int]$Altura, [int]$MinLargura = 0, [int]$MinAltura = 0)
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $Janela.MinimumSize = New-Object Drawing.Size([Math]::Min($MinLargura, $area.Width), [Math]::Min($MinAltura, $area.Height))
    $Janela.Size = New-Object Drawing.Size([Math]::Min($Largura, $area.Width), [Math]::Min($Altura, $area.Height))
}

function New-BotaoJanela {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria o controle em memória.')]
    param([Parameter(Mandatory)][string]$Texto, [switch]$Principal, [int]$Largura = 160)
    $b = New-Object Windows.Forms.Button
    $b.Text = $Texto; $b.Width = $Largura; $b.Height = 38; $b.Font = $script:FonteJanela.Normal
    $b.FlatStyle = 'Flat'; $b.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0); $b.Cursor = 'Hand'
    if ($Principal) { $b.BackColor = $script:CorJanela.Acento; $b.ForeColor = $script:CorJanela.Branco; $b.FlatAppearance.BorderSize = 0 }
    else { $b.BackColor = $script:CorJanela.Branco; $b.FlatAppearance.BorderColor = $script:CorJanela.Borda }
    $b
}

function New-RotuloJanela {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria o controle em memória.')]
    param([AllowEmptyString()][string]$Texto, $Fonte = $script:FonteJanela.Normal, $Cor = $script:CorJanela.Texto, [int]$Largura = 0)
    $l = New-Object Windows.Forms.Label
    $l.Text = $Texto; $l.Font = $Fonte; $l.ForeColor = $Cor; $l.AutoSize = $true
    if ($Largura) { $l.MaximumSize = New-Object Drawing.Size($Largura, 0) }
    $l.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
    $l
}

function New-PilhaJanela {
    <# Painel que empilha os controles de cima para baixo. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria o controle em memória.')]
    param()
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = 'TopDown'; $p.WrapContents = $false; $p.AutoScroll = $true; $p.Dock = 'Fill'
    $p
}

function Show-AvisoJanela {
    param($Janela, [Parameter(Mandatory)][string]$Texto, [string]$Titulo = 'Otimização', [string]$Icone = 'Information')
    [void][Windows.Forms.MessageBox]::Show($Janela, $Texto, $Titulo, 'OK', $Icone)
}

function Test-PerguntaJanela {
    <# Sim ou Não, com Não como padrão. #>
    param($Janela, [Parameter(Mandatory)][string]$Texto, [string]$Titulo = 'Otimização', [string]$Icone = 'Question')
    [Windows.Forms.MessageBox]::Show($Janela, $Texto, $Titulo, 'YesNo', $Icone, 'Button2') -eq 'Yes'
}

function Invoke-AcaoJanela {
    <# Executa a ação de um botão; erro inesperado vira mensagem na tela em vez de derrubar a janela. #>
    param($Janela, [Parameter(Mandatory)][scriptblock]$Acao)
    try { & $Acao }
    catch { Show-AvisoJanela -Janela $Janela -Texto "Erro inesperado: $($_.Exception.Message)" -Icone Error }
}

function New-RodapeJanela {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria o controle em memória.')]
    param()
    $r = New-Object Windows.Forms.FlowLayoutPanel; $r.Dock = 'Bottom'; $r.Height = 62; $r.FlowDirection = 'RightToLeft'
    $r.Padding = New-Object Windows.Forms.Padding(20, 12, 12, 12); $r.BackColor = $script:CorJanela.Branco
    $r
}

function Show-JanelaAcompanhamento {
    <#
        Etapas do fluxo com situação e horas, barra de progresso e fim do fluxo.log, relidos a cada IntervaloSegundos até o
        fluxo terminar. Fechar a janela não afeta o fluxo. Com PermitirCancelar (janela elevada), o botão Cancelar fluxo
        pede confirmação e cancela. Devolve $true se o fluxo foi cancelado nesta janela.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Pasta', Justification = 'Lido nos manipuladores de evento da janela.')]
    param([Parameter(Mandatory)][string]$Pasta, [switch]$PermitirCancelar, [int]$IntervaloSegundos = 10)
    $cor = $script:CorJanela
    $fonte = $script:FonteJanela
    $w = @{ Restante = $IntervaloSegundos; Cancelado = $false; Terminado = $false }

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Otimização: acompanhamento do fluxo'; Set-TamanhoJanela -Janela $f -Largura 900 -Altura 760 -MinLargura 760 -MinAltura 560
    $f.StartPosition = 'CenterScreen'; $f.Font = $fonte.Normal; $f.BackColor = $cor.Fundo

    $corpo = New-Object Windows.Forms.Panel; $corpo.Dock = 'Fill'; $corpo.Padding = New-Object Windows.Forms.Padding(20, 12, 20, 8)
    $lista = New-Object Windows.Forms.ListView
    $lista.Name = 'Etapas'; $lista.View = 'Details'; $lista.FullRowSelect = $true; $lista.Dock = 'Fill'; $lista.HeaderStyle = 'Nonclickable'; $lista.BorderStyle = 'FixedSingle'
    foreach ($c in @(@('#', 40), @('Etapa', 240), @('Situação', 130), @('Início', 80), @('Fim', 80), @('Detalhe', 300))) { [void]$lista.Columns.Add($c[0], $c[1]) }
    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.Dock = 'Bottom'; $log.Height = 130; $log.Font = $fonte.Mono
    $log.BackColor = $cor.Console; $log.ForeColor = $cor.ConsoleTexto; $log.BorderStyle = 'None'
    $rotLog = New-RotuloJanela -Texto 'Últimas linhas do registro' -Fonte $fonte.Negrito; $rotLog.Dock = 'Bottom'; $rotLog.Padding = New-Object Windows.Forms.Padding(0, 10, 0, 4)
    $cab = New-PilhaJanela; $cab.Dock = 'Top'; $cab.Height = 160; $cab.AutoScroll = $false
    $rotTitulo = New-RotuloJanela -Texto '' -Fonte $fonte.Sub
    $rotInfo = New-RotuloJanela -Texto '' -Cor $cor.Texto2 -Largura 830
    $barra = New-Object Windows.Forms.ProgressBar; $barra.Width = 830; $barra.Height = 12
    $rotAtual = New-RotuloJanela -Texto '' -Fonte $fonte.Negrito -Cor $cor.Acento -Largura 830
    $rotDica = New-RotuloJanela -Texto '' -Cor $cor.Execucao -Largura 830
    $cab.Controls.AddRange(@($rotTitulo, $rotInfo, $barra, $rotAtual, $rotDica))
    $corpo.Controls.Add($lista); $corpo.Controls.Add($log); $corpo.Controls.Add($rotLog); $corpo.Controls.Add($cab)

    $rodape = New-RodapeJanela
    $bFechar = New-BotaoJanela -Texto 'Fechar janela' -Largura 140
    $bCancelar = New-BotaoJanela -Texto 'Cancelar fluxo' -Largura 150; $bCancelar.ForeColor = $cor.Falha; $bCancelar.Visible = [bool]$PermitirCancelar
    $bAtualizar = New-BotaoJanela -Texto 'Atualizar' -Principal -Largura 120
    $rotTempo = New-RotuloJanela -Texto '' -Cor $cor.Texto2; $rotTempo.Margin = New-Object Windows.Forms.Padding(0, 9, 16, 0)
    $rodape.Controls.AddRange(@($bFechar, $bCancelar, $bAtualizar, $rotTempo))
    $f.Controls.Add($corpo); $f.Controls.Add($rodape)

    $situacao = @{ OK = 'Concluída'; Executando = 'Executando'; Pendente = 'Pendente'; Falha = 'Falha' }
    $corStatus = @{ OK = $cor.OK; Executando = $cor.Execucao; Pendente = $cor.Pendente; Falha = $cor.Falha }
    $desenhar = {
        try { $estado = Get-EstadoFluxo -Pasta $Pasta }
        catch { $rotTempo.Text = "Lendo o estado do fluxo de novo: $($_.Exception.Message)"; return }
        $c = Get-CabecalhoAcompanhamento -Estado $estado
        $rotTitulo.Text = $c.Titulo; $rotInfo.Text = $c.Info; $rotAtual.Text = $c.Atual; $rotDica.Text = $c.Dica
        $barra.Maximum = [Math]::Max(1, $c.Total); $barra.Value = [Math]::Min($c.Concluidas, $barra.Maximum)
        $lista.BeginUpdate(); $lista.Items.Clear()
        foreach ($l in Get-LinhaAcompanhamento -Estado $estado) {
            $it = New-Object Windows.Forms.ListViewItem([string]$l.Numero)
            foreach ($v in @($l.Nome, $(if ($situacao.ContainsKey($l.Status)) { $situacao[$l.Status] } else { $l.Status }), $l.Inicio, $l.Fim, $l.Detalhe)) { [void]$it.SubItems.Add([string]$v) }
            if ($corStatus.ContainsKey($l.Status)) { $it.ForeColor = $corStatus[$l.Status] }
            if ($l.Atual) { $it.BackColor = $cor.ExecucaoFundo; $it.Font = $fonte.Negrito }
            [void]$lista.Items.Add($it)
        }
        $lista.EndUpdate()
        $log.Text = (Get-FimLogFluxo -Pasta $Pasta) -join "`r`n"
        if ($estado.Status -ne 'EmAndamento') { $w.Terminado = $true; $bCancelar.Visible = $false; $bAtualizar.Visible = $false; $rotTempo.Text = 'Fluxo encerrado.' }
        else { $rotTempo.Text = "Atualiza em $($w.Restante) s" }
    }
    $relogio = New-Object Windows.Forms.Timer; $relogio.Interval = 1000
    $relogio.Add_Tick({
            if ($w.Terminado) { $relogio.Stop(); return }
            $w.Restante--
            if ($w.Restante -le 0) { $w.Restante = $IntervaloSegundos; & $desenhar }
            elseif (-not $w.Terminado) { $rotTempo.Text = "Atualiza em $($w.Restante) s" }
        })
    $bAtualizar.Add_Click({ $w.Restante = $IntervaloSegundos; & $desenhar })
    $bFechar.Add_Click({ $f.Close() })
    $bCancelar.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                $texto = "Cancelar o fluxo em andamento?`r`n`r`nSe uma etapa estiver em execução, ela termina e nada mais é executado. O que já foi aplicado continua; para desfazer, use Reverter."
                if (-not (Test-PerguntaJanela -Janela $f -Texto $texto -Titulo 'Cancelar fluxo' -Icone Warning)) { return }
                Stop-FluxoMenu -Fluxo ([pscustomobject]@{ Pasta = $Pasta; Estado = (Get-EstadoFluxo -Pasta $Pasta) })
                $w.Cancelado = $true
                & $desenhar
            }
        })
    $f.Add_FormClosed({ $relogio.Stop() })
    & $desenhar
    $relogio.Start()
    $f.Tag = $w
    [void]$f.ShowDialog()
    $f.Dispose()
    $w.Cancelado
}

function Show-JanelaConfirmacaoFluxo {
    <# Etapas do fluxo, usuário alvo, resultado da simulação e instruções; devolve $true só com Iniciar fluxo. #>
    param([Parameter(Mandatory)]$Perfil, [Parameter(Mandatory)]$Condicao, [object[]]$Simulacao = @(), $Dono)
    $cor = $script:CorJanela
    $fonte = $script:FonteJanela
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Fluxo completo'; Set-TamanhoJanela -Janela $f -Largura 780 -Altura 780; $f.StartPosition = 'CenterParent'; $f.Font = $fonte.Normal
    $f.BackColor = $cor.Fundo; $f.MinimizeBox = $false; $f.MaximizeBox = $false; $f.FormBorderStyle = 'FixedDialog'; $f.ShowInTaskbar = $false

    $pilha = New-PilhaJanela; $pilha.Padding = New-Object Windows.Forms.Padding(20, 16, 20, 8)
    $u = $Condicao.Usuario
    $pilha.Controls.Add((New-RotuloJanela -Texto "Fluxo completo: $($Perfil.Cliente)" -Fonte $fonte.Sub))
    $pilha.Controls.Add((New-RotuloJanela -Texto "Usuário alvo: $($u.Nome)$(if (-not $u.DoPerfil) { ' (usuário conectado agora; UsuarioSid vazio no perfil)' })" -Cor $cor.Texto2 -Largura 710))
    $falhas = @($Simulacao | Where-Object { $_.Codigo })
    if ($falhas.Count) {
        $pilha.Controls.Add((New-RotuloJanela -Texto ('Atenção: a simulação terminou com erro em ' + (($falhas | ForEach-Object { "$($_.Titulo) (código $($_.Codigo))" }) -join ', ') + '. Confira a saída antes de iniciar.') -Fonte $fonte.Negrito -Cor $cor.Falha -Largura 710))
    }
    else { $pilha.Controls.Add((New-RotuloJanela -Texto "Simulação de $($Condicao.Scripts -join ', ') concluída sem erro (a saída está na janela principal)." -Cor $cor.OK -Largura 710)) }
    foreach ($a in $Condicao.Avisos) { $pilha.Controls.Add((New-RotuloJanela -Texto "Aviso: $a" -Cor $cor.Execucao -Largura 710)) }
    $pilha.Controls.Add((New-RotuloJanela -Texto 'Etapas' -Fonte $fonte.Negrito))
    $etapas = New-Object Windows.Forms.ListBox; $etapas.Width = 710; $etapas.Height = 230; $etapas.BorderStyle = 'FixedSingle'; $etapas.SelectionMode = 'None'
    $n = 0; foreach ($e in Get-PlanoFluxo -Scripts $Condicao.Scripts) { $n++; [void]$etapas.Items.Add(('{0,2}.  {1}' -f $n, $e.Nome)) }
    $pilha.Controls.Add($etapas)
    $pilha.Controls.Add((New-RotuloJanela -Texto 'Durante o fluxo' -Fonte $fonte.Negrito))
    foreach ($t in @(
            'Nas três coletas, entre com o usuário do cliente logo depois de reiniciar e deixe o PC parado até ele reiniciar sozinho.'
            'A otimização roda na tela de entrada, sem ninguém conectado. Não é preciso entrar.'
            'Ao entrar com o usuário alvo depois de cada reinicialização, abre uma janela com as etapas e o andamento.'
            'Com alguém conectado, o aviso de reinicialização aparece 60 segundos antes.'
            'A Proteção do Sistema precisa estar ligada no disco do sistema: cada script cria um ponto de restauração.'
            'Duração estimada: 1 h 30 a 2 h. No fim, o resultado abre no Bloco de Notas.')) {
        $pilha.Controls.Add((New-RotuloJanela -Texto "•  $t" -Largura 710))
    }
    $alerta = New-RotuloJanela -Texto "Depois de confirmar, nada mais será perguntado. O computador reinicia em $($script:AvisoReinicioSegundos) segundos." -Fonte $fonte.Negrito -Cor $cor.Execucao -Largura 710
    $alerta.Margin = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $pilha.Controls.Add($alerta)

    $rodape = New-RodapeJanela
    $bIniciar = New-BotaoJanela -Texto 'Iniciar fluxo' -Principal; $bIniciar.DialogResult = 'OK'
    $bCancelar = New-BotaoJanela -Texto 'Cancelar'; $bCancelar.DialogResult = 'Cancel'
    $rodape.Controls.AddRange(@($bIniciar, $bCancelar))
    $f.CancelButton = $bCancelar
    $f.Controls.Add($pilha); $f.Controls.Add($rodape)
    $ok = $f.ShowDialog($Dono) -eq 'OK'
    $f.Dispose()
    $ok
}

function Show-JanelaMenu {
    <#
        Janela principal: perfis à esquerda (e Novo perfil); à direita os itens do perfil, as ações e a saída dos scripts.
        Simular, Só verificar e Reverter rodam os scripts em processo separado, um por vez, com a saída na janela.
        Devolve $true se um fluxo completo foi iniciado.
    #>
    $cor = $script:CorJanela
    $fonte = $script:FonteJanela
    $catalogo = @(Get-CatalogoPerfil)
    $ui = @{ Arquivos = @(); Escolha = $null; Fila = New-Object System.Collections.Queue; Atual = $null; AtualTitulo = $null; Resultados = $null; AoTerminar = $null; FluxoIniciado = $false }

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Otimização'; Set-TamanhoJanela -Janela $f -Largura 1200 -Altura 800 -MinLargura 980 -MinAltura 640
    $f.StartPosition = 'CenterScreen'; $f.Font = $fonte.Normal; $f.BackColor = $cor.Fundo

    $topo = New-Object Windows.Forms.Panel; $topo.Dock = 'Top'; $topo.Height = 56; $topo.BackColor = $cor.Topo
    $tit = New-RotuloJanela -Texto 'Otimização de PCs' -Fonte $fonte.Titulo -Cor $cor.Branco; $tit.Location = [Drawing.Point]::new(18, 12)
    $maq = New-Object Windows.Forms.Label; $maq.Dock = 'Right'; $maq.Width = 560; $maq.TextAlign = 'MiddleRight'; $maq.Padding = New-Object Windows.Forms.Padding(0, 0, 18, 0)
    $maq.ForeColor = $cor.Borda
    $versao = try { $so = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop; "$($so.Caption -replace '^Microsoft ', '') $($so.BuildNumber)" } catch { '' }
    $maq.Text = "$env:COMPUTERNAME   ·   Administrador   ·   $versao"
    $topo.Controls.Add($tit); $topo.Controls.Add($maq)

    $esq = New-Object Windows.Forms.Panel; $esq.Dock = 'Left'; $esq.Width = 290; $esq.BackColor = $cor.Branco; $esq.Padding = New-Object Windows.Forms.Padding(16)
    $lstPerfis = New-Object Windows.Forms.ListBox; $lstPerfis.Name = 'Perfis'; $lstPerfis.Dock = 'Fill'; $lstPerfis.BorderStyle = 'None'; $lstPerfis.IntegralHeight = $false; $lstPerfis.Font = $fonte.Lista
    $rotPerfis = New-RotuloJanela -Texto 'Perfis de cliente' -Fonte $fonte.Sub; $rotPerfis.Dock = 'Top'; $rotPerfis.Padding = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    $bNovo = New-BotaoJanela -Texto '+  Novo perfil' -Largura 250; $bNovo.Dock = 'Bottom'
    $esq.Controls.Add($lstPerfis); $esq.Controls.Add($rotPerfis); $esq.Controls.Add($bNovo)

    $dir = New-Object Windows.Forms.Panel; $dir.Dock = 'Fill'; $dir.Padding = New-Object Windows.Forms.Padding(20, 16, 20, 16)
    $cab = New-PilhaJanela; $cab.Dock = 'Top'; $cab.Height = 70; $cab.AutoScroll = $false
    $rotCliente = New-RotuloJanela -Texto 'Escolha um perfil à esquerda' -Fonte $fonte.Sub
    $rotUsuario = New-RotuloJanela -Texto '' -Cor $cor.Texto2
    $cab.Controls.AddRange(@($rotCliente, $rotUsuario))
    $acoes = New-Object Windows.Forms.FlowLayoutPanel; $acoes.Dock = 'Top'; $acoes.Height = 54; $acoes.Padding = New-Object Windows.Forms.Padding(0, 4, 0, 8)
    $bFluxo = New-BotaoJanela -Texto 'Fluxo completo' -Principal
    $bSimular = New-BotaoJanela -Texto 'Simular'
    $bVerificar = New-BotaoJanela -Texto 'Só verificar agora'
    $bReverter = New-BotaoJanela -Texto 'Reverter'
    $acoes.Controls.AddRange(@($bFluxo, $bSimular, $bVerificar, $bReverter))
    $dica = New-Object Windows.Forms.ToolTip
    $dica.SetToolTip($bFluxo, 'Coletas, otimização, reinicializações e verificação, sozinho (1 h 30 a 2 h). Simula antes e pede uma confirmação.')
    $dica.SetToolTip($bSimular, 'Mostra o que cada script mudaria. Nada é alterado.')
    $dica.SetToolTip($bVerificar, 'Compara o perfil com o estado real da máquina. Só leitura.')
    $dica.SetToolTip($bReverter, 'Desfaz o que foi aplicado para este cliente, na ordem inversa. Simula e pede confirmação antes.')
    $itens = New-Object Windows.Forms.ListView
    $itens.View = 'Details'; $itens.Dock = 'Fill'; $itens.FullRowSelect = $true; $itens.BorderStyle = 'FixedSingle'; $itens.HeaderStyle = 'Nonclickable'
    foreach ($c in @(@('Item', 70), @('Ajuste aprovado', 740))) { [void]$itens.Columns.Add($c[0], $c[1]) }
    foreach ($s in @($catalogo | ForEach-Object { $_.Script } | Select-Object -Unique)) { [void]$itens.Groups.Add($s, $s) }
    $saidaPainel = New-Object Windows.Forms.Panel; $saidaPainel.Dock = 'Bottom'; $saidaPainel.Height = 240; $saidaPainel.Padding = New-Object Windows.Forms.Padding(0, 12, 0, 0)
    $saida = New-Object Windows.Forms.TextBox; $saida.Name = 'Saida'; $saida.Multiline = $true; $saida.ReadOnly = $true; $saida.ScrollBars = 'Both'; $saida.WordWrap = $false; $saida.Dock = 'Fill'
    $saida.Font = $fonte.Mono; $saida.BackColor = $cor.Console; $saida.ForeColor = $cor.ConsoleTexto; $saida.BorderStyle = 'None'; $saida.MaxLength = 0
    $rotSaida = New-RotuloJanela -Texto 'Saída' -Fonte $fonte.Negrito; $rotSaida.Dock = 'Top'
    $saidaPainel.Controls.Add($saida); $saidaPainel.Controls.Add($rotSaida)
    $dir.Controls.Add($itens); $dir.Controls.Add($saidaPainel); $dir.Controls.Add($acoes); $dir.Controls.Add($cab)
    $f.Controls.Add($dir); $f.Controls.Add($esq); $f.Controls.Add($topo)

    $escrever = { param([string[]]$Linhas) foreach ($l in $Linhas) { $saida.AppendText("$l`r`n") } }
    $habilitar = {
        $livre = -not $ui.Atual -and -not $ui.Fila.Count -and -not $ui.AoTerminar
        $lstPerfis.Enabled = $livre; $bNovo.Enabled = $livre
        foreach ($b in @($bFluxo, $bSimular, $bVerificar, $bReverter)) { $b.Enabled = $livre -and [bool]$ui.Escolha }
        $rotSaida.Text = if ($livre) { 'Saída' } else { "Saída  (executando: $($ui.AtualTitulo))" }
    }
    $carregarPerfis = {
        param([string]$Selecionar)
        $ui.Arquivos = @(Get-ArquivoPerfil)
        $lstPerfis.Items.Clear()
        foreach ($a in $ui.Arquivos) { [void]$lstPerfis.Items.Add([IO.Path]::GetFileNameWithoutExtension($a.Name)) }
        if ($Selecionar) { $lstPerfis.SelectedIndex = [array]::IndexOf(@($ui.Arquivos | ForEach-Object { $_.FullName }), $Selecionar) }
    }
    # Fila de scripts: um por vez, a saída vai para a janela; AoTerminar roda quando a fila esvazia.
    $iniciarFila = {
        param([object[]]$Itens, [scriptblock]$AoTerminar)
        foreach ($i in $Itens) { $ui.Fila.Enqueue($i) }
        $ui.Resultados = New-Object System.Collections.Generic.List[object]
        $ui.AoTerminar = $AoTerminar
        & $habilitar
        $relogio.Start()
    }
    $relogio = New-Object Windows.Forms.Timer; $relogio.Interval = 200
    $relogio.Add_Tick({
            try {
                if ($ui.Atual) {
                    $r = Read-SaidaProcesso -Execucao $ui.Atual
                    & $escrever $r.Linhas
                    if (-not $r.Terminou) { return }
                    if ($r.Codigo) { & $escrever "($($ui.AtualTitulo) terminou com código $($r.Codigo).)" }
                    $ui.Resultados.Add([pscustomobject]@{ Titulo = $ui.AtualTitulo; Codigo = $r.Codigo })
                    $ui.Atual.Processo.Dispose()
                    $ui.Atual = $null
                }
                if ($ui.Fila.Count) {
                    $j = $ui.Fila.Dequeue()
                    $ui.AtualTitulo = $j.Titulo
                    & $escrever @('', "===== $($j.Titulo) =====")
                    $ui.Atual = Start-ProcessoScript -Arquivo $j.Arquivo -Argumentos $j.Argumentos
                    & $habilitar
                    return
                }
                $relogio.Stop()
                $fim = $ui.AoTerminar
                $ui.AoTerminar = $null
                & $habilitar
                if ($fim) { Invoke-AcaoJanela -Janela $f -Acao $fim }
            }
            catch {
                $relogio.Stop(); $ui.Fila.Clear(); $ui.Atual = $null; $ui.AoTerminar = $null
                & $escrever "Erro ao executar: $($_.Exception.Message)"
                & $habilitar
            }
        })
    $itemScript = {
        param([string]$Titulo, [string]$Script, [string[]]$Argumentos)
        [pscustomobject]@{ Titulo = $Titulo; Arquivo = (Join-Path $PSScriptRoot "$Script.ps1"); Argumentos = $Argumentos }
    }

    $lstPerfis.Add_SelectedIndexChanged({
            $ui.Escolha = $null
            $itens.Items.Clear()
            if ($lstPerfis.SelectedIndex -lt 0) { & $habilitar; return }
            $a = $ui.Arquivos[$lstPerfis.SelectedIndex]
            try { $p = Import-PerfilCliente -Caminho $a.FullName }
            catch { $rotCliente.Text = $a.Name; $rotUsuario.Text = "Perfil inválido: $($_.Exception.Message)"; & $habilitar; return }
            $ui.Escolha = [pscustomobject]@{ Caminho = $a.FullName; Perfil = $p }
            $aplicar = @($p.Aplicar | Where-Object { $p.Pular -notcontains $_ })
            $usuario = if ($p.UsuarioSid) { try { ([Security.Principal.SecurityIdentifier]$p.UsuarioSid).Translate([Security.Principal.NTAccount]).Value } catch { $p.UsuarioSid } } else { 'usuário conectado no momento do fluxo' }
            $rotCliente.Text = $p.Cliente
            $rotUsuario.Text = "Usuário alvo: $usuario    ·    $($aplicar.Count) itens    ·    $($a.Name)"
            $itens.BeginUpdate()
            foreach ($id in $aplicar) {
                $i = $catalogo | Where-Object Id -EQ $id
                $grupo = if ($i) { $itens.Groups[$i.Script] } else { $null }
                $it = New-Object Windows.Forms.ListViewItem([string]$id, $grupo)
                [void]$it.SubItems.Add($(if ($i) { $i.Texto } else { '(item fora do catálogo)' }))
                [void]$itens.Items.Add($it)
            }
            $itens.EndUpdate()
            & $habilitar
        })

    $bNovo.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                $pasta = @(Get-PastaPerfil)[0]
                if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null; Set-AcessoRestrito -Pasta $pasta }
                $novo = Show-JanelaNovoPerfil -Pasta $pasta
                & $carregarPerfis $novo
                if ($novo) { & $escrever "Perfil gravado: $novo" }
            }
        })

    $bSimular.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                $e = $ui.Escolha
                $scripts = @(Get-ScriptAplicavel -Perfil $e.Perfil)
                $saida.Clear()
                if (-not $scripts.Count) { & $escrever 'Nenhum item que altere o sistema no perfil.'; return }
                & $iniciarFila @($scripts | ForEach-Object { & $itemScript "Simulação: $_" $_ @('-Perfil', $e.Caminho, '-WhatIf') }) { & $escrever @('', 'Simulação concluída. Nada foi alterado.') }
            }
        })

    $bVerificar.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                $saida.Clear()
                & $iniciarFila @(& $itemScript 'Verificação' 'Verificacao' @('-Perfil', $ui.Escolha.Caminho)) { }
            }
        })

    $bReverter.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                $e = $ui.Escolha
                $pendentes = @(Get-PendenteReversao -Cliente $e.Perfil.Cliente)
                $saida.Clear()
                if (-not $pendentes.Count) { & $escrever "Nada a reverter para o cliente $($e.Perfil.Cliente)."; return }
                $ui.Pendentes = $pendentes
                & $iniciarFila @($pendentes | ForEach-Object { & $itemScript "Simulação da reversão: $_" $_ @('-Perfil', $e.Caminho, '-Revert', '-WhatIf') }) {
                    $texto = "Reverter $($ui.Pendentes -join ', ') nesta ordem?`r`n`r`nA simulação da reversão está na saída."
                    if (-not (Test-PerguntaJanela -Janela $f -Texto $texto -Titulo 'Reverter')) { & $escrever @('', 'Cancelado. Nada foi alterado.'); return }
                    & $iniciarFila @($ui.Pendentes | ForEach-Object { & $itemScript "Reversão: $_" $_ @('-Perfil', $ui.Escolha.Caminho, '-Revert') }) {
                        & $escrever @('', 'Reversão concluída. Reinicie o computador para que tudo volte a valer.')
                        Show-AvisoJanela -Janela $f -Texto 'Reversão concluída. Reinicie o computador para que tudo volte a valer.' -Titulo 'Reverter'
                    }
                }
            }
        })

    $bFluxo.Add_Click({
            Invoke-AcaoJanela -Janela $f -Acao {
                $e = $ui.Escolha
                $saida.Clear()
                $c = Get-CondicaoFluxo -Perfil $e.Perfil
                & $escrever @($c.Avisos | ForEach-Object { "Aviso: $_" })
                & $escrever @($c.Bloqueios | ForEach-Object { "Bloqueio: $_" })
                if ($c.Erro) { & $escrever $c.Erro; Show-AvisoJanela -Janela $f -Texto $c.Erro -Titulo 'Fluxo completo' -Icone Warning; return }
                $ui.Condicao = $c
                & $iniciarFila @($c.Scripts | ForEach-Object { & $itemScript "Simulação: $_" $_ @('-Perfil', $e.Caminho, '-WhatIf') }) {
                    if (-not (Show-JanelaConfirmacaoFluxo -Perfil $ui.Escolha.Perfil -Condicao $ui.Condicao -Simulacao $ui.Resultados.ToArray() -Dono $f)) {
                        & $escrever @('', 'Fluxo cancelado. Nada foi alterado.'); return
                    }
                    $pasta = Start-FluxoOtimizacao -PerfilOrigem $ui.Escolha.Caminho -UsuarioSid $ui.Condicao.Usuario.Sid
                    & $escrever "Fluxo iniciado. Pasta: $pasta"
                    Invoke-FluxoOtimizacao -Pasta $pasta
                    $ui.FluxoIniciado = $true
                    Show-AvisoJanela -Janela $f -Texto "Fluxo iniciado. O computador vai reiniciar em $($script:AvisoReinicioSegundos) segundos. Depois disso, siga as instruções da confirmação." -Titulo 'Fluxo completo'
                    $f.Close()
                }
            }
        })

    $f.Add_FormClosing({
            if (($ui.Atual -or $ui.Fila.Count) -and -not $ui.FluxoIniciado) {
                Show-AvisoJanela -Janela $f -Texto "Aguarde terminar: $($ui.AtualTitulo)." -Titulo 'Otimização'
                $_.Cancel = $true
            }
        })
    $f.Add_FormClosed({ $relogio.Stop() })

    & $carregarPerfis
    & $habilitar
    $f.Tag = $ui
    [void]$f.ShowDialog()
    $f.Dispose()
    $ui.FluxoIniciado
}

function Show-MenuPrincipal {
    if (-not (Test-Administrador)) { throw 'Execute o Menu como administrador (botão direito no PowerShell, Executar como administrador).' }
    Initialize-Interface
    # Carregado só aqui: o fluxo no boot não precisa do catálogo nem das funções de leitura do Novo perfil.
    . (Join-Path $PSScriptRoot 'Perfil.ps1')
    while ($true) {
        $andamento = @(Get-FluxoEmAndamento)
        if ($andamento.Count) {
            # Com fluxo em andamento, a janela de acompanhamento é o menu; cancelado, volta aos perfis.
            if (-not (Show-JanelaAcompanhamento -Pasta $andamento[0].Pasta -PermitirCancelar)) { return }
            continue
        }
        if (-not (Show-JanelaMenu)) { return }
    }
}

function Invoke-Acompanhar {
    <# Janela aberta pela tarefa no logon do usuário alvo. Cancelar o fluxo só aparece se ela estiver elevada. #>
    param([Parameter(Mandatory)][string]$Pasta)
    Initialize-Interface
    [void](Show-JanelaAcompanhamento -Pasta $Pasta -PermitirCancelar:(Test-Administrador))
}

#endregion

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    if ($Continuar) { Invoke-FluxoOtimizacao -Pasta $Continuar }
    elseif ($Acompanhar) { Invoke-Acompanhar -Pasta $Acompanhar }
    else { Show-MenuPrincipal }
}
