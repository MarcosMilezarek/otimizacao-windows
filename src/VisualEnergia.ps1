<#
.SYNOPSIS
    Efeitos visuais, energia e ajustes de uso (itens V1 a V10 do catálogo) conforme o perfil do cliente.

.DESCRIPTION
    Aplica somente os itens V* listados em Aplicar no perfil e não listados em Pular.
    Itens do usuário (HKCU) são gravados no perfil do usuário alvo (UsuarioSid do perfil ou usuário do console),
    mesmo que o script rode em outra conta elevada. Efeito visual completo após o usuário sair e entrar de novo.

      V1  Animações desligadas: animação de menus, caixas de combinação, rolagem suave, esmaecimento de menus,
          seleção e dicas (bits de UserPreferencesMask), animação ao minimizar e maximizar (MinAnimate) e
          animações da barra de tarefas. Mantém suavização de fontes, miniaturas e sombras.
      V2  Transparência desligada (EnableTransparency).
      V3  Plano de energia "Desempenho máximo", sempre (decisão do responsável). Cria uma cópia do plano
          e9a42b02-d5df-448d-aa00-03f14749eb61 com GUID fixo deste projeto e a ativa. Em Modern Standby (S0) o
          Windows não oferece o plano: tenta Alto desempenho e, se também indisponível, mantém o plano atual e registra.
      V4  Modo de energia "Melhor desempenho" na tomada (sobreposição do plano Equilibrado). Só tem efeito com o plano
          Equilibrado ativo, ou seja, quando V3 não pôde ativar outro plano. API não documentada do powrprof.dll.
      V5  Inicialização rápida: mantida. Só é desligada com Opcoes.V5DesligarInicializacaoRapida = $true no perfil.
      V6  Hibernação desligada (powercfg /hibernate off), apenas em desktop. Libera o hiberfil.sys e desliga a
          inicialização rápida.
      V7  Num Lock ligado na inicialização (tela de entrada e usuário alvo). No usuário alvo só é gravado com ele
          desconectado: com ele conectado, o Windows grava o estado atual do Num Lock ao sair e o valor se perderia.
      V8  Mostrar extensões de arquivos conhecidos.
      V9  "Finalizar tarefa" no menu da barra de tarefas (Windows 11 23H2, build 22631, ou superior).
      V10 Desliga o atalho das Teclas de Aderência (Shift 5 vezes), limpando o bit SKF_HOTKEYACTIVE.

    Antes de alterar: pré-checagens, ponto de restauração confirmado e backup dos valores originais em
    %ProgramData%\Otimizacao\<Cliente>\<data>-VisualEnergia.

.PARAMETER Perfil
    Arquivo .psd1 do cliente.

.PARAMETER Revert
    Reverte todas as sessões de aplicação ainda não revertidas, da mais recente para a mais antiga (ou só a indicada
    em -Sessao): valores de registro, plano de energia, modo de energia e hibernação voltam ao original; o plano
    criado pelo script é excluído.

.PARAMETER Sessao
    Pasta da sessão a reverter.

.PARAMETER PermitirReinicializacaoPendente
    Não bloqueia a execução quando há reinicialização pendente.

.EXAMPLE
    .\VisualEnergia.ps1 -Perfil .\perfis\ClienteX.psd1 -WhatIf

.EXAMPLE
    .\VisualEnergia.ps1 -Perfil .\perfis\ClienteX.psd1 -Revert

.NOTES
    O que se perde: V1 e V2 removem animações e transparência. V3 aumenta consumo de energia e temperatura e,
    em notebook, reduz a autonomia da bateria. V6 desliga hibernação e inicialização rápida (boot a frio mais lento).
    V10 desliga o atalho de acessibilidade (o recurso continua disponível em Configurações).
    Reversão: -Revert restaura todos os itens.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Aplicar')]
param(
    [Parameter(Mandatory)]
    [string]$Perfil,

    [Parameter(ParameterSetName = 'Reverter', Mandatory)]
    [switch]$Revert,

    [Parameter(ParameterSetName = 'Reverter')]
    [string]$Sessao,

    [switch]$PermitirReinicializacaoPendente
)

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

$script:NomeScript = 'VisualEnergia'
# GUIDs de planos: learn.microsoft.com/windows-hardware/customize/power-settings
$script:GuidDesempenhoMaximo = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:GuidAltoDesempenho = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:GuidEquilibrado = '381b4222-f694-41f0-9685-ff5bb260df2e'
# Cópia do Desempenho máximo criada por este projeto (GUID fixo, permite detectar e remover na reversão).
$script:GuidPlanoProjeto = '584bf86a-6f70-4264-8c40-c11fb7951f47'
$script:GuidOverlayMelhorDesempenho = 'ded574b5-45a0-4f42-8737-46345c09c238'
$script:ChavePlanos = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'

#region Energia: APIs

if (-not ('Otimizacao.Energia' -as [type])) {
    Add-Type -Namespace Otimizacao -Name Energia -MemberDefinition @'
[DllImport("powrprof.dll")] public static extern uint CallNtPowerInformation(int level, System.IntPtr inBuf, uint inLen, byte[] outBuf, uint outLen);
[DllImport("powrprof.dll")] public static extern uint PowerSetActiveOverlayScheme(System.Guid overlay);
[DllImport("powrprof.dll")] public static extern uint PowerGetActualOverlayScheme(out System.Guid overlay);
'@
}

function Get-CapacidadeEnergia {
    <#
        SYSTEM_POWER_CAPABILITIES (CallNtPowerInformation nível 4, winnt.h): byte 5 SystemS3,
        byte 8 HiberFilePresent, byte 20 AoAc (Modern Standby).
    #>
    $buf = New-Object byte[] 76
    $r = [Otimizacao.Energia]::CallNtPowerInformation(4, [IntPtr]::Zero, 0, $buf, 76)
    if ($r -ne 0) { throw "CallNtPowerInformation falhou (0x{0:X})." -f $r }
    [pscustomobject]@{ S3 = [bool]$buf[5]; Hibernacao = [bool]$buf[8]; ModernStandby = [bool]$buf[20] }
}

function Get-PlanoAtivo {
    (Get-ItemProperty -LiteralPath $script:ChavePlanos).ActivePowerScheme
}

function Test-PlanoExiste {
    param([string]$Guid)
    Test-Path -LiteralPath (Join-Path $script:ChavePlanos $Guid)
}

function Invoke-Powercfg {
    param([Parameter(Mandatory)][string[]]$Argumentos)
    $saida = & "$env:windir\System32\powercfg.exe" @Argumentos 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($Argumentos -join ' ') falhou ($LASTEXITCODE): $($saida | Out-String)" }
}

function Test-NaTomada {
    $baterias = @(Get-CimInstance Win32_Battery)
    -not ($baterias.Count -and @($baterias | Where-Object { $_.BatteryStatus -ne 2 }).Count)
}

#endregion

#region Itens do usuário (HKCU do usuário alvo)

function Invoke-ItemUsuario {
    <# Executa os itens V1, V2, V7, V8, V9 e V10 que estiverem na lista, dentro do hive do usuário alvo. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parâmetros usados no scriptblock executado no hive do usuário.')]
    param($Sessao, $Alvo, [string[]]$Itens, $Info)
    Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
        param($raiz)
        $comum = @{ Sessao = $Sessao; Raiz = $raiz; Escopo = 'Usuario'; Sid = $Alvo.Sid }
        $exp = 'Software\Microsoft\Windows\CurrentVersion\Explorer'

        if ($Itens -contains 'V1') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'V1' -Acao {
                Set-ValorRegistro @comum -Item 'V1' -SubChave "$exp\VisualEffects" -Nome 'VisualFXSetting' -Valor 3 | Out-Null
                $mascara = (Get-ValorRegistro -Caminho "$raiz\Control Panel\Desktop" -Nome 'UserPreferencesMask').Valor
                if ($mascara) {
                    $nova = [byte[]]$mascara.Clone()
                    # Byte 0: 0x02 animação de menus, 0x04 caixas de combinação, 0x08 rolagem suave de listas.
                    # Byte 1: 0x02 esmaecer menus, 0x04 esmaecer seleção, 0x08 animar dicas, 0x10 esmaecer dicas.
                    $nova[0] = $nova[0] -band (-bnot 0x0E)
                    $nova[1] = $nova[1] -band (-bnot 0x1E)
                    Set-ValorRegistro @comum -Item 'V1' -SubChave 'Control Panel\Desktop' -Nome 'UserPreferencesMask' -Valor $nova -Tipo Binary | Out-Null
                }
                Set-ValorRegistro @comum -Item 'V1' -SubChave 'Control Panel\Desktop\WindowMetrics' -Nome 'MinAnimate' -Valor '0' -Tipo String | Out-Null
                Set-ValorRegistro @comum -Item 'V1' -SubChave "$exp\Advanced" -Nome 'TaskbarAnimations' -Valor 0 | Out-Null
            }
        }
        if ($Itens -contains 'V2') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'V2' -Acao {
                Set-ValorRegistro @comum -Item 'V2' -SubChave 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Nome 'EnableTransparency' -Valor 0 | Out-Null
            }
        }
        if ($Itens -contains 'V7') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'V7' -Acao {
                # O Windows grava o estado atual do Num Lock neste valor ao sair da sessão e ao desligar
                # (learn.microsoft.com/previous-versions/windows/it-pro/windows-2000-server/cc978657; medido na VM: 2 virou 0
                # após reiniciar). Com o usuário conectado o valor seria sobrescrito: só grava com o hive carregado pelo script.
                $atualNum = Get-ValorRegistro -Caminho "$raiz\Control Panel\Keyboard" -Nome 'InitialKeyboardIndicators'
                if ($raiz -notlike '*\Otimizacao_*' -and [string]$atualNum.Valor -ne '2') {
                    return Write-LogOtimizacao -Sessao $Sessao -Item 'V7' -Alvo 'Control Panel\Keyboard\InitialKeyboardIndicators' -ValorAnterior $atualNum.Valor -Resultado Pulado `
                        -Detalhe 'Usuário conectado: o Windows grava o estado atual do Num Lock ao sair. Ligue o Num Lock e saia da sessão, ou execute com o usuário desconectado.' | Out-Null
                }
                Set-ValorRegistro @comum -Item 'V7' -SubChave 'Control Panel\Keyboard' -Nome 'InitialKeyboardIndicators' -Valor '2' -Tipo String | Out-Null
            }
        }
        if ($Itens -contains 'V8') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'V8' -Acao {
                Set-ValorRegistro @comum -Item 'V8' -SubChave "$exp\Advanced" -Nome 'HideFileExt' -Valor 0 | Out-Null
            }
        }
        if ($Itens -contains 'V9') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'V9' -Acao {
                if ($Info.Build -lt 22631) {
                    return Write-LogOtimizacao -Sessao $Sessao -Item 'V9' -Alvo 'TaskbarEndTask' -Resultado Pulado -Detalhe "Requer Windows 11 build 22631 ou superior (atual $($Info.Build))." | Out-Null
                }
                Set-ValorRegistro @comum -Item 'V9' -SubChave "$exp\Advanced\TaskbarDeveloperSettings" -Nome 'TaskbarEndTask' -Valor 1 | Out-Null
            }
        }
        if ($Itens -contains 'V10') {
            Invoke-ItemOtimizacao -Sessao $Sessao -Id 'V10' -Acao {
                $sub = 'Control Panel\Accessibility\StickyKeys'
                $atual = Get-ValorRegistro -Caminho "$raiz\$sub" -Nome 'Flags'
                $flags = if ($atual.Existe) { [int]$atual.Valor } else { 510 }
                # SKF_HOTKEYACTIVE = 0x4 (estrutura STICKYKEYS, winuser.h)
                Set-ValorRegistro @comum -Item 'V10' -SubChave $sub -Nome 'Flags' -Valor ([string]($flags -band (-bnot 0x4))) -Tipo String | Out-Null
            }
        }
    }
}

#endregion

#region Itens da máquina

function Invoke-V3 {
    param($Sessao)
    $cap = Get-CapacidadeEnergia
    $original = Get-PlanoAtivo
    $nomeAlvo = 'Desempenho máximo'
    $alvo = $script:GuidPlanoProjeto

    if ($original -eq $alvo) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V3' -Alvo 'Plano de energia' -ValorAnterior $original -ValorNovo $alvo -Resultado JaAplicado | Out-Null
    }
    if ($Sessao.Simular) {
        $obs = if ($cap.ModernStandby) { 'Modern Standby: o Windows pode não oferecer o plano; haverá tentativa e fallback.' } else { $null }
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V3' -Alvo 'Plano de energia' -ValorAnterior $original -ValorNovo "$nomeAlvo ($alvo)" -Resultado Simulado -Detalhe $obs | Out-Null
    }

    $criado = $false
    $ativado = $false
    try {
        if (-not (Test-PlanoExiste $alvo)) {
            Invoke-Powercfg -Argumentos @('/duplicatescheme', $script:GuidDesempenhoMaximo, $alvo)
            $criado = $true
        }
        Invoke-Powercfg -Argumentos @('/setactive', $alvo)
        $ativado = (Get-PlanoAtivo) -eq $alvo
    }
    catch { Write-Verbose "Desempenho máximo indisponível: $($_.Exception.Message)" }

    if (-not $ativado -and (Test-PlanoExiste $script:GuidAltoDesempenho)) {
        $nomeAlvo = 'Alto desempenho (fallback)'
        $alvo = $script:GuidAltoDesempenho
        try { Invoke-Powercfg -Argumentos @('/setactive', $alvo); $ativado = (Get-PlanoAtivo) -eq $alvo } catch { Write-Verbose $_.Exception.Message }
    }

    Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'PlanoEnergia'; Item = 'V3'; Original = $original; Criado = $(if ($criado) { $script:GuidPlanoProjeto } else { $null }) }

    if (-not $ativado) {
        $motivo = if ($cap.ModernStandby) { 'Modern Standby (S0): o Windows só oferece o plano Equilibrado. V4 aplica o modo Melhor desempenho.' } else { 'Planos de desempenho indisponíveis.' }
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V3' -Alvo 'Plano de energia' -ValorAnterior $original -ValorNovo $original -Resultado Pulado -Detalhe $motivo | Out-Null
    }
    $detalhe = if ($cap.ModernStandby) { 'Modern Standby: verificar após reiniciar se o plano permanece ativo.' } else { $null }
    Write-LogOtimizacao -Sessao $Sessao -Item 'V3' -Alvo 'Plano de energia' -ValorAnterior $original -ValorNovo "$nomeAlvo ($alvo)" -Resultado OK -Detalhe $detalhe | Out-Null
}

function Invoke-V4 {
    param($Sessao)
    $plano = Get-PlanoAtivo
    if ($plano -ne $script:GuidEquilibrado) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia' -Resultado Pulado -Detalhe "Só se aplica ao plano Equilibrado (ativo: $plano)." | Out-Null
    }
    if (-not (Test-NaTomada)) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia' -Resultado Pulado -Detalhe 'Na bateria: o item vale para a tomada. Execute conectado.' | Out-Null
    }
    $atual = [guid]::Empty
    [void][Otimizacao.Energia]::PowerGetActualOverlayScheme([ref]$atual)
    $novo = [guid]$script:GuidOverlayMelhorDesempenho
    if ($atual -eq $novo) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia (tomada)' -ValorAnterior $atual -Resultado JaAplicado | Out-Null
    }
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia (tomada)' -ValorAnterior $atual -ValorNovo $novo -Resultado Simulado | Out-Null
    }
    Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'Overlay'; Item = 'V4'; Original = $atual.ToString() }
    $r = [Otimizacao.Energia]::PowerSetActiveOverlayScheme($novo)
    if ($r -ne 0) { throw "PowerSetActiveOverlayScheme falhou (0x{0:X})." -f $r }
    $lido = [guid]::Empty
    [void][Otimizacao.Energia]::PowerGetActualOverlayScheme([ref]$lido)
    if ($lido -ne $novo) { throw 'Modo de energia lido de volta diverge do aplicado.' }
    Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia (tomada)' -ValorAnterior $atual -ValorNovo $novo -Resultado OK | Out-Null
}

function Invoke-V5 {
    param($Sessao, [bool]$Desligar)
    $sub = 'SYSTEM\CurrentControlSet\Control\Session Manager\Power'
    $atual = Get-ValorRegistro -Caminho "Registry::HKEY_LOCAL_MACHINE\$sub" -Nome 'HiberbootEnabled'
    if (-not $Desligar) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V5' -Alvo 'Inicialização rápida' -ValorAnterior $atual.Valor -Resultado Info -Detalhe 'Mantida (padrão). Desligar só com Opcoes.V5DesligarInicializacaoRapida.' | Out-Null
    }
    Set-ValorRegistro -Sessao $Sessao -Item 'V5' -Raiz 'Registry::HKEY_LOCAL_MACHINE' -SubChave $sub -Nome 'HiberbootEnabled' -Valor 0 | Out-Null
}

function Invoke-V6 {
    param($Sessao)
    if ((Get-TipoEquipamento) -ne 'Desktop') {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V6' -Alvo 'Hibernação' -Resultado Pulado -Detalhe 'Notebook: hibernação mantida.' | Out-Null
    }
    $ligada = (Get-CapacidadeEnergia).Hibernacao
    if (-not $ligada) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V6' -Alvo 'Hibernação' -ValorAnterior 'desligada' -Resultado JaAplicado | Out-Null
    }
    $arquivo = Join-Path $env:SystemDrive 'hiberfil.sys'
    $tam = (Get-ChildItem -LiteralPath $env:SystemDrive -Filter 'hiberfil.sys' -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Length
    $antes = 'ligada ({0} MB)' -f [math]::Round($tam / 1MB)
    if ($Sessao.Simular) {
        return Write-LogOtimizacao -Sessao $Sessao -Item 'V6' -Alvo $arquivo -ValorAnterior $antes -ValorNovo 'desligada' -Resultado Simulado | Out-Null
    }
    Add-EstadoOriginal -Sessao $Sessao -Entrada @{ Tipo = 'Hibernacao'; Item = 'V6'; Ligada = $true }
    Invoke-Powercfg -Argumentos @('/hibernate', 'off')
    if ((Get-CapacidadeEnergia).Hibernacao) { throw 'Hibernação continua ligada após powercfg.' }
    Write-LogOtimizacao -Sessao $Sessao -Item 'V6' -Alvo $arquivo -ValorAnterior $antes -ValorNovo 'desligada' -Resultado OK | Out-Null
}

function Invoke-V7Maquina {
    param($Sessao)
    # Tela de entrada (perfil .DEFAULT).
    Set-ValorRegistro -Sessao $Sessao -Item 'V7' -Raiz 'Registry::HKEY_USERS' -Escopo Maquina -SubChave '.DEFAULT\Control Panel\Keyboard' -Nome 'InitialKeyboardIndicators' -Valor '2' -Tipo String | Out-Null
}

#endregion

#region Reversão de entradas que não são registro

function Get-ManipuladorReversao {
    <# Manipuladores de reversão. Invoke-Reversao passa a entrada e a sessão como argumentos. #>
    @{
        PlanoEnergia = {
            param($e, $Sessao)
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item 'V3' -Alvo 'Plano de energia' -ValorNovo $e.Original -Resultado Simulado }
            Invoke-Powercfg -Argumentos @('/setactive', $e.Original)
            if ((Get-PlanoAtivo) -ne $e.Original) { throw 'Plano original não voltou a ficar ativo.' }
            if ($e.Criado -and (Test-PlanoExiste $e.Criado)) { Invoke-Powercfg -Argumentos @('/delete', $e.Criado) }
            Write-LogOtimizacao -Sessao $Sessao -Item 'V3' -Alvo 'Plano de energia' -ValorNovo $e.Original -Resultado Revertido
        }
        Overlay      = {
            param($e, $Sessao)
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia' -ValorNovo $e.Original -Resultado Simulado }
            $r = [Otimizacao.Energia]::PowerSetActiveOverlayScheme([guid]$e.Original)
            if ($r -ne 0) { throw "PowerSetActiveOverlayScheme falhou (0x{0:X})." -f $r }
            Write-LogOtimizacao -Sessao $Sessao -Item 'V4' -Alvo 'Modo de energia' -ValorNovo $e.Original -Resultado Revertido
        }
        Hibernacao   = {
            param($e, $Sessao)
            if ($Sessao.Simular) { return Write-LogOtimizacao -Sessao $Sessao -Item 'V6' -Alvo 'Hibernação' -ValorNovo 'ligada' -Resultado Simulado }
            Invoke-Powercfg -Argumentos @('/hibernate', 'on')
            if (-not (Get-CapacidadeEnergia).Hibernacao) { throw 'Hibernação não voltou a ficar ligada.' }
            Write-LogOtimizacao -Sessao $Sessao -Item $e.Item -Alvo 'Hibernação' -ValorNovo 'ligada' -Resultado Revertido
        }
    }
}

#endregion

#region Execução

function Invoke-VisualEnergia {
    param([string]$Perfil, [switch]$Revert, [string]$Sessao, [switch]$PermitirReinicializacaoPendente, [switch]$Simular)

    $p = Import-PerfilCliente -Caminho $Perfil
    $pre = Test-PreCondicao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente
    foreach ($a in $pre.Avisos) { Write-Warning $a }
    if ($pre.Bloqueios.Count) {
        foreach ($b in $pre.Bloqueios) { Write-Warning "BLOQUEIO: $b" }
        if (-not $Simular) { throw 'Execução bloqueada pelas pré-checagens. Nada foi alterado.' }
    }

    # A sessão da reversão tem nome próprio para não ser confundida com uma sessão de aplicação pendente.
    $nomeSessao = if ($Revert) { "$($script:NomeScript)-Reversao" } else { $script:NomeScript }
    $s = New-SessaoOtimizacao -Cliente $p.Cliente -Script $nomeSessao -Simular:$Simular

    if ($Revert) {
        Invoke-ReversaoPendente -Sessao $s -Cliente $p.Cliente -Script $script:NomeScript -Pasta $Sessao -Manipuladores (Get-ManipuladorReversao)
        return $s
    }

    $itens = Get-ItemPerfil -Perfil $p -Prefixo 'V'
    if (-not $itens.Count) { Write-Warning 'Nenhum item V* no perfil. Nada a fazer.'; return }
    $info = Get-InfoWindows
    $alvoUsuario = Get-UsuarioAlvo -Sid $p.UsuarioSid
    Write-LogOtimizacao -Sessao $s -Item 'Contexto' -Alvo 'Usuário alvo' -ValorNovo $alvoUsuario.Sid -Resultado Info -Detalhe "Executado por $env:USERDOMAIN\$env:USERNAME" | Out-Null

    if (-not $Simular) {
        try {
            $rp = New-PontoRestauracao -Descricao "Otimizacao $($script:NomeScript) $($p.Cliente)"
            Write-LogOtimizacao -Sessao $s -Item 'Backup' -Alvo 'Ponto de restauração' -ValorNovo $rp.SequenceNumber -Resultado OK | Out-Null
        }
        catch {
            Write-LogOtimizacao -Sessao $s -Item 'Backup' -Alvo 'Ponto de restauração' -Resultado Falha -Detalhe $_.Exception.Message | Out-Null
            throw "Backup falhou: nada foi alterado. $($_.Exception.Message)"
        }
    }

    $desligarV5 = [bool]($p.Opcoes.ContainsKey('V5DesligarInicializacaoRapida') -and $p.Opcoes.V5DesligarInicializacaoRapida)
    if ($itens -contains 'V3') { Invoke-ItemOtimizacao -Sessao $s -Id 'V3' -Acao { Invoke-V3 -Sessao $s } }
    if ($itens -contains 'V4') { Invoke-ItemOtimizacao -Sessao $s -Id 'V4' -Acao { Invoke-V4 -Sessao $s } }
    if ($itens -contains 'V5') { Invoke-ItemOtimizacao -Sessao $s -Id 'V5' -Acao { Invoke-V5 -Sessao $s -Desligar $desligarV5 } }
    if ($itens -contains 'V6') { Invoke-ItemOtimizacao -Sessao $s -Id 'V6' -Acao { Invoke-V6 -Sessao $s } }
    if ($itens -contains 'V7') { Invoke-ItemOtimizacao -Sessao $s -Id 'V7' -Acao { Invoke-V7Maquina -Sessao $s } }

    $doUsuario = @($itens | Where-Object { $_ -in 'V1', 'V2', 'V7', 'V8', 'V9', 'V10' })
    if ($doUsuario.Count) {
        Invoke-ItemOtimizacao -Sessao $s -Id 'Usuario' -Acao { Invoke-ItemUsuario -Sessao $s -Alvo $alvoUsuario -Itens $doUsuario -Info $info }
    }
    $s
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    $s = Invoke-VisualEnergia -Perfil $Perfil -Revert:$Revert -Sessao $Sessao -PermitirReinicializacaoPendente:$PermitirReinicializacaoPendente -Simular:([bool]$WhatIfPreference)
    if ($s) {
        $s.Linhas | Format-Table -Property Item, Alvo, ValorAnterior, ValorNovo, Resultado, Detalhe -AutoSize -Wrap | Out-String -Width 220
        Get-ResumoSessao -Sessao $s | Format-Table -AutoSize | Out-String
        if ($s.Pasta) { "Sessão: $($s.Pasta)" }
        if (@($s.Linhas | Where-Object Resultado -eq 'Falha').Count) { exit 1 }
    }
}

#endregion
