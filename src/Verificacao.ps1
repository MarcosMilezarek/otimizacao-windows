<#
.SYNOPSIS
    Verificação final, somente leitura: confirma no estado real do sistema o que cada script de otimização aplicou.

.DESCRIPTION
    Executada por último, depois da reinicialização final (o Menu a executa no fim do fluxo completo). Para cada item
    aprovado no perfil (Aplicar menos Pular), lê o estado atual do sistema e compara com o que o script deveria ter
    deixado. Não usa log nem código de saída dos scripts. Das pastas de sessão em %ProgramData%\Otimizacao\<Cliente>
    usa só a existência (o script rodou) e o arquivo revertido.txt (o script foi revertido com -Revert).

    Saída em dois blocos:
      1. Alterado: estado esperado confirmado no sistema.
      2. Não alterado ou com erro: não aplicado, mantido por regra do projeto, definido por política, script não
         executado ou revertido, ou não verificável. Um motivo por linha.
    Confiança alta, salvo indicação na própria linha.

    Checagens por script:
      Manutencao    M1 e M2 não verificáveis sem repetir a varredura. M3 estado de saúde dos volumes (Get-Volume,
                    confiança média). M4 DisableDeleteNotification 0 ou ausente, com SSD. M8 três políticas do horário ativo.
      Aplicativos   A1 e A4 pacotes ausentes para todos os usuários e no provisionamento. A2 padrões de Opcoes.A2Remover
                    ausentes entre os programas da máquina.
      Inicializacao I1 entrada desabilitada em StartupApproved. I2 a I5, I8, I11 e I12 valores das políticas. I6 pacote
                    ausente. I7 valor gravado (efeito no Iniciar não verificável). I9 tarefa desabilitada. I10 tipo de início.
      VisualEnergia V1, V2 e V7 a V10 no registro do usuário alvo (V7 também na tela de entrada). V3 plano ativo. V4 modo de
                    energia na tomada. V5 HiberbootEnabled. V6 hibernação pela API de energia.
      Limpeza       L1, L2 e L5 sem arquivo elegível restante (confiança média: arquivos novos surgem e a ausência não prova a
                    limpeza). L3, L4 e L7 não verificáveis. L6 Windows.old ausente. L8 SSD tarefa de otimização habilitada,
                    HDD análise de fragmentação (confiança média). L9 quatro políticas.
    Listas e funções de leitura vêm dos próprios scripts, carregados com dot-source (só definem funções, não executam).

.PARAMETER Perfil
    Arquivo .psd1 do cliente.

.PARAMETER IdadeMinimaDias
    Mesma idade mínima usada na Limpeza para L1 e L2. Padrão: 7.

.PARAMETER Relatorio
    Arquivo de texto (UTF-8) onde gravar também a mensagem. Sem ele, a saída fica só na tela.

.EXAMPLE
    .\Verificacao.ps1 -Perfil .\perfis\ClienteX.psd1

.NOTES
    O que altera: nada. Exceção, igual à Coleta: se o usuário alvo não estiver conectado, o NTUSER.DAT dele é carregado
    só para leitura e descarregado ao final. Com -Relatorio, grava somente o arquivo indicado.
    O que se perde: nada. Reversão: não se aplica.
    Exige administrador (pacotes de todos os usuários, componentes opcionais, hive do usuário alvo).
    Rodar depois da reinicialização final: V7 e o V3 em Modern Standby só se confirmam após reiniciar.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Perfil,

    [ValidateRange(0, 365)]
    [int]$IdadeMinimaDias = 7,

    [string]$Relatorio
)

# Com dot-source os scripts só definem funções e constantes. O bloco param de cada um redefine as variáveis de mesmo
# nome neste escopo: por isso -Perfil e -IdadeMinimaDias são repassados com os valores recebidos.
foreach ($arquivoScript in 'Manutencao', 'Aplicativos', 'Inicializacao', 'VisualEnergia') {
    . (Join-Path $PSScriptRoot "$arquivoScript.ps1") -Perfil $Perfil
}
. (Join-Path $PSScriptRoot 'Limpeza.ps1') -Perfil $Perfil -IdadeMinimaDias $IdadeMinimaDias

$script:RaizSessoes = Join-Path $env:ProgramData 'Otimizacao'

# Ordem do fluxo aprovada. Prefixo do catálogo por script.
$script:ScriptsVerificados = @(
    [pscustomobject]@{ Nome = 'Manutencao'; Prefixo = 'M' }
    [pscustomobject]@{ Nome = 'Aplicativos'; Prefixo = 'A' }
    [pscustomobject]@{ Nome = 'Inicializacao'; Prefixo = 'I' }
    [pscustomobject]@{ Nome = 'VisualEnergia'; Prefixo = 'V' }
    [pscustomobject]@{ Nome = 'Limpeza'; Prefixo = 'L' }
)

$script:Titulos = @{
    M1 = 'Imagem do Windows (DISM)'; M2 = 'Arquivos de sistema (SFC)'; M3 = 'Sistema de arquivos'; M4 = 'TRIM do SSD'
    M5 = 'Dispositivos com erro'; M6 = 'Eventos de disco e hardware'; M7 = 'Relatório de bateria'; M8 = 'Horário ativo do Windows Update'
    A1 = 'Apps de consumo'; A2 = 'Programas do fabricante'; A3 = 'OneDrive'; A4 = 'Teams pessoal'
    I1 = 'Programas na inicialização'; I2 = 'Edge em segundo plano'; I3 = 'Chrome em segundo plano'; I4 = 'Apps da Store em segundo plano'
    I5 = 'Widgets'; I6 = 'App Copilot'; I7 = 'Sugestões da web na busca'; I8 = 'Gravação em segundo plano do Game Bar'
    I9 = 'Tarefas agendadas'; I10 = 'Serviços'; I11 = 'Sugestões e apps sugeridos'; I12 = 'Recall e Click to Do'
    V1 = 'Animações'; V2 = 'Transparência'; V3 = 'Plano de energia'; V4 = 'Modo de energia na tomada'; V5 = 'Inicialização rápida'
    V6 = 'Hibernação'; V7 = 'Num Lock ao iniciar'; V8 = 'Extensões de arquivos'; V9 = 'Finalizar tarefa na barra de tarefas'
    V10 = 'Atalho das Teclas de Aderência'
    L1 = 'Temporários do Windows'; L2 = 'Temporários dos usuários'; L3 = 'Cache dos navegadores'; L4 = 'Cache do Windows Update'
    L5 = 'Lixeira'; L6 = 'Windows.old'; L7 = 'Limpeza de componentes do Windows'; L8 = 'Otimização de disco'; L9 = 'Sensor de Armazenamento'
}

$script:NomesPlano = @{
    '584bf86a-6f70-4264-8c40-c11fb7951f47' = 'Desempenho máximo (cópia do projeto)'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Desempenho máximo'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'Alto desempenho'
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Equilibrado'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Economia de energia'
}

# Valores do usuário alvo lidos de uma vez dentro do hive (SubChave, Nome). A vírgula unária mantém cada par como
# um item: sem ela, @( @(a, b) @(c, d) ) vira uma lista plana de textos.
$script:Explorer = 'Software\Microsoft\Windows\CurrentVersion\Explorer'
$script:LeiturasUsuario = @(
    , @("$($script:Explorer)\VisualEffects", 'VisualFXSetting')
    , @('Control Panel\Desktop', 'UserPreferencesMask')
    , @('Control Panel\Desktop\WindowMetrics', 'MinAnimate')
    , @("$($script:Explorer)\Advanced", 'TaskbarAnimations')
    , @('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'EnableTransparency')
    , @('Control Panel\Keyboard', 'InitialKeyboardIndicators')
    , @("$($script:Explorer)\Advanced", 'HideFileExt')
    , @("$($script:Explorer)\Advanced\TaskbarDeveloperSettings", 'TaskbarEndTask')
    , @('Control Panel\Accessibility\StickyKeys', 'Flags')
    , @('Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions')
    , @('Software\Policies\Microsoft\Windows\CloudContent', 'DisableThirdPartySuggestions')
)

#region Resultados e comparação

function New-Verificado {
    <# Bloco 1: estado esperado confirmado no sistema. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria objeto em memória.')]
    param([string]$Item, [string]$Detalhe, [string]$Confianca = 'alta')
    [pscustomobject]@{ Item = $Item; Alterado = $true; Texto = "$($script:Titulos[$Item]): $Detalhe"; Confianca = $Confianca }
}

function New-Pendente {
    <# Bloco 2: não alterado, mantido por regra, revertido, com erro ou não verificável (Confianca vazia). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Só cria objeto em memória.')]
    param([string]$Item, [string]$Detalhe, [string]$Confianca = 'alta')
    $texto = if ($script:Titulos.ContainsKey($Item)) { "$($script:Titulos[$Item]): $Detalhe" } else { $Detalhe.Substring(0, 1).ToUpper() + $Detalhe.Substring(1) }
    [pscustomobject]@{ Item = $Item; Alterado = $false; Texto = $texto; Confianca = $Confianca }
}

function ConvertTo-Minuscula {
    param([string]$Texto)
    if (-not $Texto) { return $Texto }
    $Texto.Substring(0, 1).ToLower() + $Texto.Substring(1)
}

function ConvertTo-TextoValor {
    param($Valor)
    if ($null -eq $Valor) { return '(vazio)' }
    if ($Valor -is [byte[]]) { return ($Valor | ForEach-Object { $_.ToString('X2') }) -join ' ' }
    if ($Valor -is [array]) { return ($Valor | ForEach-Object { [string]$_ }) -join ', ' }
    [string]$Valor
}

function Get-ValorVerificado {
    <# Valor de máquina (HKLM) lido agora, ou do usuário alvo lido no hive por Get-DadoUsuario. #>
    param([ValidateSet('Maquina', 'Usuario')][string]$Escopo, [string]$SubChave, [string]$Nome)
    if ($Escopo -eq 'Maquina') { return Get-ValorRegistro -Caminho "Registry::HKEY_LOCAL_MACHINE\$SubChave" -Nome $Nome }
    $script:DadoUsuario.Valores["$SubChave\$Nome"]
}

function Get-Divergencia {
    <# Valores que diferem do esperado: Nome, Existe e Atual. #>
    param([string]$Escopo, [string]$SubChave, [Parameter(Mandatory)]$Valores)
    foreach ($n in @($Valores.Keys)) {
        $v = Get-ValorVerificado -Escopo $Escopo -SubChave $SubChave -Nome $n
        if (-not $v.Existe -or -not (Test-ValorIgual $v.Valor $Valores[$n])) { [pscustomobject]@{ Nome = $n; Existe = $v.Existe; Atual = $v.Valor } }
    }
}

function Get-MotivoDivergencia {
    <# Política (gravada pelo script com PularSeDefinido): valor existente com outro conteúdo indica política de terceiros. #>
    param([Parameter(Mandatory)]$Lista, [switch]$Politica)
    $texto = (@($Lista) | ForEach-Object { if ($_.Existe) { "$($_.Nome) = $(ConvertTo-TextoValor $_.Atual)" } else { "$($_.Nome) ausente" } }) -join '; '
    $motivo = if ($Politica -and @($Lista | Where-Object { $_.Existe }).Count) { 'não alterado, já existe política com outro valor, definida pela empresa, MDM ou outra ferramenta' } else { 'não aplicado' }
    "$motivo ($texto)."
}

function Test-Esperado {
    <# Compara um grupo de valores de registro com o esperado e devolve o resultado do item. #>
    param([string]$Item, [string]$Escopo = 'Maquina', [string]$SubChave, [Parameter(Mandatory)]$Valores, [string]$Feito, [switch]$Politica)
    if ($Escopo -eq 'Usuario' -and -not $script:DadoUsuario) { return New-Pendente $Item "não verificável, $($script:MotivoUsuario)." -Confianca '' }
    $dif = @(Get-Divergencia -Escopo $Escopo -SubChave $SubChave -Valores $Valores)
    if (-not $dif.Count) { return New-Verificado $Item $Feito }
    New-Pendente $Item (Get-MotivoDivergencia $dif -Politica:$Politica)
}

function Test-BitLigado {
    <# Valor numérico (texto ou DWORD) com o bit indicado ligado. #>
    param($Valor, [long]$Bit)
    if (-not $Valor -or -not $Valor.Existe) { return $false }
    $n = 0L
    [long]::TryParse([string]$Valor.Valor, [ref]$n) -and ($n -band $Bit)
}

#endregion

#region Contexto: sessões e usuário alvo

function Get-EstadoExecucao {
    <# Só metadados da pasta: existe sessão de aplicação do script e, na mais recente, revertido.txt. #>
    param([Parameter(Mandatory)][string]$Cliente, [Parameter(Mandatory)][string]$Script, [string]$Raiz = $script:RaizSessoes)
    $pastas = @(Get-ChildItem -LiteralPath (Join-Path $Raiz $Cliente) -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-$Script" } | Sort-Object -Property Name -Descending)
    if (-not $pastas.Count) { return [pscustomobject]@{ Executado = $false; Revertido = $false; Data = $null } }
    $data = [datetime]::ParseExact($pastas[0].Name.Substring(0, 15), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{ Executado = $true; Revertido = (Test-Path -LiteralPath (Join-Path $pastas[0].FullName 'revertido.txt')); Data = $data }
}

function Get-EstadoEntradaInicializacao {
    <# Entradas de inicialização com o nome indicado e se estão desabilitadas (StartupApproved, bit 0 do primeiro byte). #>
    param([string]$Raiz, [string]$Escopo, [string]$PerfilUsuario, [string[]]$Nomes)
    foreach ($e in @(Get-FonteInicializacao -Raiz $Raiz -Escopo $Escopo -PerfilUsuario $PerfilUsuario)) {
        if ($Nomes -notcontains $e.Nome) { continue }
        $v = Get-ValorRegistro -Caminho "$($e.Raiz)\$($e.SubAprov)" -Nome $e.Nome
        $desabilitada = [bool]($v.Existe -and $v.Valor -is [byte[]] -and $v.Valor.Length -and ($v.Valor[0] -band 1))
        $e | Add-Member -NotePropertyName Desabilitada -NotePropertyValue $desabilitada -PassThru
    }
}

function Get-DadoUsuario {
    <# Lê de uma vez, no hive do usuário alvo, os valores de LeiturasUsuario e as entradas de inicialização do I1. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'NomesI1', Justification = 'Usado no scriptblock executado no hive do usuário.')]
    param([Parameter(Mandatory)]$Alvo, [string[]]$NomesI1)
    Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
        param($raiz)
        $valores = @{}
        foreach ($l in $script:LeiturasUsuario) { $valores["$($l[0])\$($l[1])"] = Get-ValorRegistro -Caminho "$raiz\$($l[0])" -Nome $l[1] }
        $entradas = @(if ($NomesI1) { Get-EstadoEntradaInicializacao -Raiz $raiz -Escopo Usuario -PerfilUsuario $Alvo.Perfil -Nomes $NomesI1 })
        [pscustomobject]@{ Valores = $valores; EntradasI1 = $entradas }
    }
}

#endregion

#region Manutencao

function Test-ItemManutencao {
    param([string]$Id, $Perfil, $Info)
    switch ($Id) {
        'M1' { New-Pendente M1 'não verificável sem repetir a varredura do DISM (o item só diagnostica; o resultado está na saída do Manutencao).' -Confianca '' }
        'M2' { New-Pendente M2 'não verificável sem repetir o sfc (o item só diagnostica; o resultado está na saída do Manutencao).' -Confianca '' }
        'M3' {
            $ok = New-Object System.Collections.Generic.List[string]
            foreach ($letra in Get-VolumeVerificavel) {
                # MSFT_Volume.HealthStatus: 0 ou Healthy = íntegro.
                $saude = [string](Get-Volume -DriveLetter $letra -ErrorAction Stop).HealthStatus
                if ($saude -in 'Healthy', '0') { $ok.Add("$($letra):") }
                else { New-Pendente M3 "$($letra): com estado $saude. Agendar Repair-Volume -DriveLetter $letra -SpotFix numa janela de manutenção, com backup antes." }
            }
            if ($ok.Count) { New-Verificado M3 "$($ok -join ', ') sem erros indicados pelo Windows (estado do volume, sem repetir a varredura)." -Confianca 'média' }
        }
        'M4' {
            if (-not (Test-TemSsd)) { return New-Pendente M4 'não se aplica, nenhum SSD identificado.' }
            $t = Get-EstadoTrim
            if (-not $t.Existe -or [string]$t.Valor -eq '0') { New-Verificado M4 'ligado.' }
            else { New-Pendente M4 "não aplicado (DisableDeleteNotification = $($t.Valor))." }
        }
        { $_ -in 'M5', 'M6', 'M7' } { New-Pendente $Id 'item só de leitura, feito pela Coleta: nada a alterar.' -Confianca '' }
        'M8' {
            if ($Info.EditionId -like 'Core*') { return New-Pendente M8 'não se aplica ao Windows Home.' }
            $h = Get-HorarioAtivo -Perfil $Perfil
            if (-not $h) { return New-Pendente M8 'horário não definido no perfil (Opcoes.M8Inicio e M8Fim).' }
            $valores = [ordered]@{ ActiveHoursStart = $h.Inicio; ActiveHoursEnd = $h.Fim; SetActiveHours = 1 }
            Test-Esperado -Item M8 -SubChave $script:SubChaveWu -Valores $valores -Feito "das $($h.Inicio) h às $($h.Fim) h, sem reinício automático nesse período." -Politica
        }
    }
}

#endregion

#region Aplicativos

function Get-MotivoAppxPresente {
    <# Por que um pacote que deveria ter saído continua: regra do projeto, sem Store, só provisionado ou falha. #>
    param($Pacote, [string]$Nome, $Perfil, [bool]$Loja, [switch]$A2)
    $ref = $Pacote.Instalados | Select-Object -First 1
    $exib = if ($ref) { Get-NomeExibicaoAppx -Pacote $ref } else { [pscustomobject]@{ Nome = $Nome; Fabricante = $null } }
    $rotulo = if ($exib.Nome -ne $Nome) { "$($exib.Nome) ($Nome)" } else { $Nome }
    $regra = if (@($Pacote.Instalados | Where-Object { $_.NonRemovable -or $_.IsFramework -or [string]$_.SignatureKind -eq 'System' }).Count) { 'Pacote do sistema, framework ou não removível.' }
    else { Get-MotivoProibido -Programa ([pscustomobject]@{ Nome = $exib.Nome; Id = $Nome; Fabricante = $exib.Fabricante }) -Perfil $Perfil -A2:$A2 }
    $motivo = if ($regra) { "mantido por regra, $(ConvertTo-Minuscula $regra)" }
    elseif (-not $Loja) { 'mantido, sem Microsoft Store não haveria como reinstalar.' }
    elseif (-not $Pacote.Instalados.Count) { 'ainda provisionado, volta em contas novas.' }
    else { 'ainda instalado.' }
    "$rotulo $motivo"
}

function Test-ItemAplicativo {
    param([string]$Id, $Perfil, [bool]$Loja)
    switch ($Id) {
        'A1' {
            $ausentes = 0
            foreach ($nome in $script:ListaA1) {
                $p = Get-PacoteAppx -Nome $nome
                if (-not $p.Instalados.Count -and -not $p.Provisionados.Count) { $ausentes++; continue }
                New-Pendente A1 (Get-MotivoAppxPresente -Pacote $p -Nome $nome -Perfil $Perfil -Loja $Loja)
            }
            if ($ausentes) { New-Verificado A1 "$ausentes de $($script:ListaA1.Count) apps da lista base não estão instalados." }
        }
        'A2' {
            $padroes = @(Get-Opcao $Perfil 'A2Remover' | Where-Object { $_ })
            if (-not $padroes.Count) { return New-Pendente A2 'lista vazia no perfil (Opcoes.A2Remover).' }
            $programas = @(Get-ProgramaMaquina)
            foreach ($padrao in $padroes) {
                $achados = @($programas | Where-Object { $_.Nome -like $padrao -or $_.Id -like $padrao })
                if (-not $achados.Count) { New-Verificado A2 "$padrao não está mais instalado."; continue }
                foreach ($prog in $achados) {
                    if ($prog.Tipo -eq 'Appx') { New-Pendente A2 (Get-MotivoAppxPresente -Pacote (Get-PacoteAppx -Nome $prog.Id) -Nome $prog.Id -Perfil $Perfil -Loja $Loja -A2); continue }
                    $rotulo = "$($prog.Nome) $($prog.Versao)".Trim()
                    $regra = Get-MotivoProibido -Programa $prog -Perfil $Perfil -A2
                    $motivo = if ($regra) { "mantido por regra, $(ConvertTo-Minuscula $regra)" }
                    elseif ($prog.Tipo -eq 'EXE') { 'instalador EXE, remoção manual em Configurações > Aplicativos.' }
                    else { 'ainda instalado.' }
                    New-Pendente A2 "$rotulo $motivo"
                }
            }
        }
        'A3' { New-Pendente A3 'não se aplica, o OneDrive não é removido (decisão do projeto). Para tirá-lo da inicialização, use o I1.' }
        'A4' {
            $p = Get-PacoteAppx -Nome $script:PacoteA4
            if (-not $p.Instalados.Count -and -not $p.Provisionados.Count) { New-Verificado A4 'não está instalado.' }
            else { New-Pendente A4 (Get-MotivoAppxPresente -Pacote $p -Nome $script:PacoteA4 -Perfil $Perfil -Loja $Loja) }
        }
    }
}

#endregion

#region Inicializacao

function Test-ItemInicializacao {
    param([string]$Id, $Perfil, $Info)
    $pol = 'SOFTWARE\Policies'
    switch ($Id) {
        'I1' {
            $nomes = @(Get-Opcao $Perfil 'I1Desabilitar' | Where-Object { $_ })
            if (-not $nomes.Count) { return New-Pendente I1 'lista vazia no perfil (Opcoes.I1Desabilitar).' }
            $entradas = @(Get-EstadoEntradaInicializacao -Raiz $script:HKLM -Escopo Maquina -Nomes $nomes)
            if ($script:DadoUsuario) { $entradas += @($script:DadoUsuario.EntradasI1) }
            else { New-Pendente I1 "entradas do usuário alvo não verificáveis, $($script:MotivoUsuario)." -Confianca '' }
            $desligadas = New-Object System.Collections.Generic.List[string]
            foreach ($e in $entradas) {
                if (Test-ComponenteWindows $e.Comando) { New-Pendente I1 "$($e.Nome) mantido por regra, componente do Windows."; continue }
                if (Test-Protegido -Perfil $Perfil -Categoria 'Inicializacao' -Nome $e.Nome) { New-Pendente I1 "$($e.Nome) mantido, protegido no perfil."; continue }
                if ($e.Desabilitada) { $desligadas.Add($e.Nome) } else { New-Pendente I1 "$($e.Nome) ainda inicia com o Windows." }
            }
            if ($desligadas.Count) { New-Verificado I1 "não iniciam mais com o Windows: $($desligadas -join ', ')." }
            $achados = @($entradas | ForEach-Object { $_.Nome })
            foreach ($n in $nomes | Where-Object { $achados -notcontains $_ }) {
                if ($script:DadoUsuario) { New-Pendente I1 "$n não encontrado (programa removido ou nome diferente do mostrado na Coleta)." }
            }
        }
        'I2' {
            if (-not (Test-AppInstalado 'msedge.exe')) { return New-Pendente I2 'não se aplica, Edge não instalado.' }
            Test-Esperado -Item I2 -SubChave "$pol\Microsoft\Edge" -Valores ([ordered]@{ StartupBoostEnabled = 0; BackgroundModeEnabled = 0 }) -Feito 'desligado (inicialização acelerada e execução com o Edge fechado).' -Politica
        }
        'I3' {
            if (-not (Test-AppInstalado 'chrome.exe')) { return New-Pendente I3 'não se aplica, Chrome não instalado.' }
            Test-Esperado -Item I3 -SubChave "$pol\Google\Chrome" -Valores @{ BackgroundModeEnabled = 0 } -Feito 'desligado com o Chrome fechado.' -Politica
        }
        'I4' {
            $apps = @(Get-Opcao $Perfil 'I4NegarSegundoPlano' | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            if (-not $apps.Count) { return New-Pendente I4 'lista vazia no perfil (Opcoes.I4NegarSegundoPlano).' }
            $sub = "$pol\Microsoft\Windows\AppPrivacy"
            $dif = @(Get-Divergencia -Escopo Maquina -SubChave $sub -Valores @{ LetAppsRunInBackground = 0 })
            $lista = Get-ValorVerificado -Escopo Maquina -SubChave $sub -Nome 'LetAppsRunInBackground_ForceDenyTheseApps'
            $faltam = @($apps | Where-Object { -not $lista.Existe -or @($lista.Valor) -notcontains $_ })
            if ($faltam.Count) { $dif += [pscustomobject]@{ Nome = 'LetAppsRunInBackground_ForceDenyTheseApps'; Existe = $lista.Existe; Atual = $lista.Valor } }
            if (-not $dif.Count) { New-Verificado I4 "negado para $($apps -join ', ')." } else { New-Pendente I4 (Get-MotivoDivergencia $dif -Politica) }
        }
        'I5' {
            if ($Info.Build -lt 22000) { return New-Pendente I5 'não se aplica ao Windows 10.' }
            $r = Test-Esperado -Item I5 -SubChave "$pol\Microsoft\Dsh" -Valores @{ AllowNewsAndInterests = 0 } -Feito 'desligados.' -Politica
            if (-not $r.Alterado -and (Test-UcpdAtivo)) { return New-Pendente I5 (ConvertTo-Minuscula $script:MotivoI5Ucpd) }
            $r
        }
        'I6' {
            $p = Get-PacoteAppx -Nome $script:PacoteCopilot
            if (-not $p.Instalados.Count -and -not $p.Provisionados.Count) { New-Verificado I6 'não está instalado.' }
            else { New-Pendente I6 "ainda presente ($(@($p.Instalados).Count) instalação(ões), $(@($p.Provisionados).Count) provisionamento(s))." }
        }
        'I7' {
            Test-Esperado -Item I7 -Escopo Usuario -SubChave 'Software\Policies\Microsoft\Windows\Explorer' -Valores @{ DisableSearchBoxSuggestions = 1 } -Feito 'desligadas no usuário alvo (valor gravado).' -Politica
            New-Pendente I7 'efeito no menu Iniciar não verificável (sem documentação da Microsoft): conferir buscando um termo no Iniciar.' -Confianca 'baixa'
        }
        'I8' { Test-Esperado -Item I8 -SubChave "$pol\Microsoft\Windows\GameDVR" -Valores @{ AllowGameDVR = 0 } -Feito 'desligada.' -Politica }
        'I9' {
            $lista = @(Get-Opcao $Perfil 'I9Tarefas' | Where-Object { $_ })
            if (-not $lista.Count) { return New-Pendente I9 'lista vazia no perfil (Opcoes.I9Tarefas).' }
            foreach ($completo in $lista) {
                $i = $completo.LastIndexOf('\')
                if (-not $completo.StartsWith('\') -or $i -lt 0) { New-Pendente I9 "$completo fora do formato '\Pasta\Nome' no perfil."; continue }
                $caminho = $completo.Substring(0, $i + 1); $nome = $completo.Substring($i + 1)
                if ($caminho -like '\Microsoft\*') { New-Pendente I9 "$completo mantida por regra, tarefa do Windows."; continue }
                if ((Test-Protegido -Perfil $Perfil -Categoria 'Tarefas' -Nome $completo) -or (Test-Protegido -Perfil $Perfil -Categoria 'Tarefas' -Nome $nome)) { New-Pendente I9 "$completo mantida, protegida no perfil."; continue }
                $t = Get-ScheduledTask -TaskPath $caminho -TaskName $nome -ErrorAction SilentlyContinue
                if (-not $t) { New-Pendente I9 "$completo não encontrada (programa removido ou nome diferente)."; continue }
                if ([string]$t.State -eq 'Disabled') { New-Verificado I9 "$completo desabilitada." } else { New-Pendente I9 "$completo ainda habilitada (estado $($t.State))." }
            }
        }
        'I10' {
            $mapa = Get-Opcao $Perfil 'I10Servicos'
            if (-not $mapa -or -not $mapa.Count) { return New-Pendente I10 'lista vazia no perfil (Opcoes.I10Servicos).' }
            $codigos = @{ Manual = 3; Disabled = 4 }
            $nomesInicio = @{ 2 = 'Automático'; 3 = 'Manual'; 4 = 'Desativado' }
            foreach ($nome in @($mapa.Keys)) {
                $destino = [string]$mapa[$nome]
                if (-not $codigos.ContainsKey($destino)) { New-Pendente I10 "$nome com destino '$destino' inválido no perfil."; continue }
                if (Test-Protegido -Perfil $Perfil -Categoria 'Servicos' -Nome $nome) { New-Pendente I10 "$nome mantido, protegido no perfil."; continue }
                $atual = Get-InicioServico $nome
                if (-not $atual) { New-Pendente I10 "$nome não encontrado (programa removido ou nome diferente)."; continue }
                if (-not ($atual.Tipo -band 0x30) -or $atual.Start -lt 2) { New-Pendente I10 "$nome mantido por regra, driver ou serviço de boot."; continue }
                if (Test-ComponenteWindows $atual.ImagePath) { New-Pendente I10 "$nome mantido por regra, serviço do Windows."; continue }
                if ($atual.Start -eq $codigos[$destino]) { New-Verificado I10 "$nome com início $($nomesInicio[$atual.Start])." }
                else { New-Pendente I10 "$nome não aplicado (início $(if ($nomesInicio.ContainsKey($atual.Start)) { $nomesInicio[$atual.Start] } else { $atual.Start }), esperado $($nomesInicio[$codigos[$destino]]))." }
            }
        }
        'I11' {
            if (-not $script:DadoUsuario) { return New-Pendente I11 "não verificável, $($script:MotivoUsuario)." -Confianca '' }
            $dif = @(Get-Divergencia -Escopo Usuario -SubChave 'Software\Policies\Microsoft\Windows\CloudContent' -Valores @{ DisableThirdPartySuggestions = 1 })
            if ($Info.EditionId -match '^(Enterprise|Education)') {
                $dif += @(Get-Divergencia -Escopo Maquina -SubChave "$pol\Microsoft\Windows\CloudContent" -Valores ([ordered]@{ DisableWindowsConsumerFeatures = 1; DisableSoftLanding = 1 }))
            }
            if (-not $dif.Count) { New-Verificado I11 'desligadas.' } else { New-Pendente I11 (Get-MotivoDivergencia $dif -Politica) }
        }
        'I12' {
            $estado = Get-EstadoRecall
            if (-not $estado -or $estado -eq 'DisabledWithPayloadRemoved') { return New-Pendente I12 'não se aplica, não é PC Copilot+.' }
            Test-Esperado -Item I12 -SubChave "$pol\Microsoft\Windows\WindowsAI" -Valores ([ordered]@{ DisableAIDataAnalysis = 1; DisableClickToDo = 1 }) -Feito 'desligados.' -Politica
        }
    }
}

#endregion

#region VisualEnergia

function Get-NomePlano {
    param([string]$Guid)
    if ($script:NomesPlano.ContainsKey($Guid.ToLower())) { $script:NomesPlano[$Guid.ToLower()] } else { $Guid }
}

function Test-ItemVisualEnergia {
    param([string]$Id, $Perfil, $Info)
    $adv = "$($script:Explorer)\Advanced"
    switch ($Id) {
        'V1' {
            if (-not $script:DadoUsuario) { return New-Pendente V1 "não verificável, $($script:MotivoUsuario)." -Confianca '' }
            $dif = @(Get-Divergencia -Escopo Usuario -SubChave "$($script:Explorer)\VisualEffects" -Valores @{ VisualFXSetting = 3 })
            $dif += @(Get-Divergencia -Escopo Usuario -SubChave 'Control Panel\Desktop\WindowMetrics' -Valores @{ MinAnimate = '0' })
            $dif += @(Get-Divergencia -Escopo Usuario -SubChave $adv -Valores @{ TaskbarAnimations = 0 })
            # Bits de animação que o V1 limpa (byte 0: 0x0E; byte 1: 0x1E). Sem a máscara, o V1 não a grava.
            $m = Get-ValorVerificado -Escopo Usuario -SubChave 'Control Panel\Desktop' -Nome 'UserPreferencesMask'
            if ($m.Existe -and -not ($m.Valor -is [byte[]] -and $m.Valor.Length -ge 2 -and -not ($m.Valor[0] -band 0x0E) -and -not ($m.Valor[1] -band 0x1E))) {
                $dif += [pscustomobject]@{ Nome = 'UserPreferencesMask'; Existe = $true; Atual = $m.Valor }
            }
            if (-not $dif.Count) { New-Verificado V1 'desligadas (menus, listas, dicas, janelas e barra de tarefas).' } else { New-Pendente V1 (Get-MotivoDivergencia $dif) }
        }
        'V2' { Test-Esperado -Item V2 -Escopo Usuario -SubChave 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Valores @{ EnableTransparency = 0 } -Feito 'desligada.' }
        'V3' {
            $ativo = [string](Get-PlanoAtivo)
            $cap = Get-CapacidadeEnergia
            if ($ativo -eq $script:GuidPlanoProjeto) { return New-Verificado V3 'Desempenho máximo ativo.' }
            if ($ativo -eq $script:GuidAltoDesempenho -and -not (Test-PlanoExiste $script:GuidPlanoProjeto)) { return New-Verificado V3 'Alto desempenho ativo (Desempenho máximo indisponível neste PC).' }
            if ($ativo -eq $script:GuidEquilibrado -and $cap.ModernStandby) { return New-Pendente V3 'mantido Equilibrado, em Modern Standby o Windows não oferece os planos de desempenho (o V4 cobre o modo de energia).' }
            New-Pendente V3 "não aplicado (plano ativo: $(Get-NomePlano $ativo))."
        }
        'V4' {
            $ativo = [string](Get-PlanoAtivo)
            if ($ativo -ne $script:GuidEquilibrado) { return New-Pendente V4 "não necessário, vale só com o plano Equilibrado (ativo: $(Get-NomePlano $ativo))." }
            if (-not (Test-NaTomada)) { return New-Pendente V4 'não verificável na bateria, o modo vale para a tomada. Conecte e verifique de novo.' -Confianca '' }
            $g = [guid]::Empty
            [void][Otimizacao.Energia]::PowerGetActualOverlayScheme([ref]$g)
            # API não documentada do powrprof.dll: confiança média.
            if ($g -eq [guid]$script:GuidOverlayMelhorDesempenho) { New-Verificado V4 'Melhor desempenho.' -Confianca 'média' }
            else { New-Pendente V4 "não aplicado (modo atual $g)." -Confianca 'média' }
        }
        'V5' {
            if (-not ($Perfil.Opcoes.ContainsKey('V5DesligarInicializacaoRapida') -and $Perfil.Opcoes.V5DesligarInicializacaoRapida)) {
                return New-Pendente V5 'mantida ligada (padrão do projeto; desligar só com Opcoes.V5DesligarInicializacaoRapida).'
            }
            Test-Esperado -Item V5 -SubChave 'SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Valores @{ HiberbootEnabled = 0 } -Feito 'desligada.'
        }
        'V6' {
            if ((Get-TipoEquipamento) -ne 'Desktop') { return New-Pendente V6 'mantida por regra, notebook.' }
            if (-not (Get-CapacidadeEnergia).Hibernacao) { New-Verificado V6 'desligada (hiberfil.sys liberado).' } else { New-Pendente V6 'ainda ligada.' }
        }
        'V7' {
            # InitialKeyboardIndicators: bit 2 = Num Lock ligado (o Windows também grava 2147483650 = 0x80000002).
            $tela = Test-BitLigado (Get-ValorRegistro -Caminho 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' -Nome 'InitialKeyboardIndicators') 2
            if (-not $script:DadoUsuario) {
                if ($tela) { New-Verificado V7 'ligado na tela de entrada.' } else { New-Pendente V7 'não aplicado na tela de entrada.' }
                return New-Pendente V7 "usuário alvo não verificável, $($script:MotivoUsuario)." -Confianca ''
            }
            $usuario = Test-BitLigado (Get-ValorVerificado -Escopo Usuario -SubChave 'Control Panel\Keyboard' -Nome 'InitialKeyboardIndicators') 2
            if ($tela -and $usuario) { return New-Verificado V7 'ligado na tela de entrada e no usuário alvo.' }
            if ($tela) { New-Verificado V7 'ligado na tela de entrada.' } else { New-Pendente V7 'não aplicado na tela de entrada.' }
            if (-not $usuario) { New-Pendente V7 'não aplicado no usuário alvo (o Windows grava o estado do Num Lock ao sair: ligue o Num Lock e saia da sessão).' }
        }
        'V8' { Test-Esperado -Item V8 -Escopo Usuario -SubChave $adv -Valores @{ HideFileExt = 0 } -Feito 'visíveis.' }
        'V9' {
            if ($Info.Build -lt 22631) { return New-Pendente V9 "não se aplica, requer Windows 11 23H2 ou superior (build atual $($Info.Build))." }
            Test-Esperado -Item V9 -Escopo Usuario -SubChave "$adv\TaskbarDeveloperSettings" -Valores @{ TaskbarEndTask = 1 } -Feito 'disponível no menu da barra de tarefas.'
        }
        'V10' {
            if (-not $script:DadoUsuario) { return New-Pendente V10 "não verificável, $($script:MotivoUsuario)." -Confianca '' }
            # SKF_HOTKEYACTIVE = 0x4 (estrutura STICKYKEYS, winuser.h). Sem o valor, o padrão do Windows tem o atalho ligado.
            $f = Get-ValorVerificado -Escopo Usuario -SubChave 'Control Panel\Accessibility\StickyKeys' -Nome 'Flags'
            $n = 0L
            if ($f.Existe -and [long]::TryParse([string]$f.Valor, [ref]$n) -and -not ($n -band 4)) { New-Verificado V10 'desligado (Shift 5 vezes não ativa mais).' }
            else { New-Pendente V10 "não aplicado (Flags = $(if ($f.Existe) { $f.Valor } else { 'ausente' }))." }
        }
    }
}

#endregion

#region Limpeza

function Get-ResumoArquivo {
    param([object[]]$Arquivos)
    $a = @($Arquivos | Where-Object { $_ })
    '{0} arquivo(s), {1}' -f $a.Count, (Format-Tamanho ([long]($a | Measure-Object -Property Length -Sum).Sum))
}

function Test-ItemLimpeza {
    param([string]$Id, [int]$IdadeMinimaDias)
    $naoVerificavel = 'não verificável, {0}'
    switch ($Id) {
        'L1' {
            $a = @(Get-ArquivoLimpeza -Pasta (Join-Path $env:windir 'Temp') -IdadeMinimaDias $IdadeMinimaDias)
            if (-not $a.Count) { New-Verificado L1 "nenhum arquivo com mais de $IdadeMinimaDias dias." -Confianca 'média' }
            else { New-Pendente L1 "restam $(Get-ResumoArquivo $a) com mais de $IdadeMinimaDias dias, provavelmente em uso." -Confianca 'média' }
        }
        'L2' {
            $a = @(foreach ($perfil in Get-PastaPerfilUsuario) { Get-ArquivoLimpeza -Pasta (Join-Path $perfil 'AppData\Local\Temp') -IdadeMinimaDias $IdadeMinimaDias })
            if (-not $a.Count) { New-Verificado L2 "nenhum arquivo com mais de $IdadeMinimaDias dias nos perfis." -Confianca 'média' }
            else { New-Pendente L2 "restam $(Get-ResumoArquivo $a) com mais de $IdadeMinimaDias dias, provavelmente em uso." -Confianca 'média' }
        }
        'L3' { New-Pendente L3 ($naoVerificavel -f 'o cache se refaz com o uso do navegador.') -Confianca '' }
        'L4' { New-Pendente L4 ($naoVerificavel -f 'o Windows Update baixa de novo o que estiver pendente.') -Confianca '' }
        'L5' {
            $a = @(foreach ($letra in Get-UnidadeFixa) {
                    foreach ($pasta in @(Get-ChildItem -LiteralPath "$($letra):\`$Recycle.Bin" -Directory -Force -ErrorAction SilentlyContinue)) {
                        Get-ArquivoLimpeza -Pasta $pasta.FullName -Excluir 'desktop.ini'
                    }
                })
            if (-not $a.Count) { New-Verificado L5 'vazia.' -Confianca 'média' }
            else { New-Pendente L5 "tem $(Get-ResumoArquivo $a), que podem ter sido apagados depois da limpeza." -Confianca 'média' }
        }
        'L6' {
            if (-not (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'Windows.old'))) { New-Verificado L6 'removida (ou não existia).' }
            else { New-Pendente L6 'ainda existe.' }
        }
        'L7' { New-Pendente L7 ($naoVerificavel -f 'o resultado só aparece no texto traduzido do DISM.') -Confianca '' }
        'L8' {
            $temSsd = $false
            foreach ($letra in Get-UnidadeFixa) {
                $midia = try { Get-MidiaUnidade -Letra $letra } catch { 'Unspecified' }
                if ($midia -eq 'SSD') { $temSsd = $true; continue }
                if ($midia -ne 'HDD') { New-Pendente L8 "$($letra): tipo de mídia não identificado (comum em VM e RAID), não verificável." -Confianca ''; continue }
                # Win32_Volume.DefragAnalysis: só analisa, não move arquivos.
                $r = Invoke-CimMethod -Query "SELECT * FROM Win32_Volume WHERE DriveLetter='$($letra):'" -MethodName DefragAnalysis
                if ($r.ReturnValue -ne 0) { New-Pendente L8 "$($letra): (HDD) análise de fragmentação falhou (código $($r.ReturnValue)), não verificável." -Confianca '' }
                elseif ($r.DefragRecommended) { New-Pendente L8 "$($letra): (HDD) o Windows ainda recomenda desfragmentar." -Confianca 'média' }
                else { New-Verificado L8 "$($letra): (HDD) sem necessidade de desfragmentar." -Confianca 'média' }
            }
            if ($temSsd) {
                $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop
                if ([string]$t.State -ne 'Disabled') { New-Verificado L8 'otimização automática do SSD (TRIM) agendada e habilitada.' }
                else { New-Pendente L8 'tarefa de otimização automática (ScheduledDefrag) desabilitada.' }
            }
        }
        'L9' {
            $valores = [ordered]@{
                AllowStorageSenseGlobal = 1; AllowStorageSenseTemporaryFilesCleanup = 1
                ConfigStorageSenseRecycleBinCleanupThreshold = 0; ConfigStorageSenseDownloadsCleanupThreshold = 0
            }
            Test-Esperado -Item L9 -SubChave 'SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Valores $valores -Feito 'ligado, limpa temporários e nunca a Lixeira nem Downloads.' -Politica
        }
    }
}

#endregion

#region Execução

function Invoke-Checagem {
    <# Isola erro por item: uma falha de leitura vira linha do bloco 2 e a verificação continua. #>
    param([Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][scriptblock]$Acao)
    try { & $Acao }
    catch { New-Pendente $Item "erro ao verificar ($($_.Exception.Message))." -Confianca '' }
}

function Get-ResultadoVerificacao {
    <# Resultados de todos os itens do perfil, na ordem do fluxo. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'IdadeMinimaDias', Justification = 'Usado no scriptblock passado a Invoke-Checagem.')]
    param([Parameter(Mandatory)]$Perfil, [int]$IdadeMinimaDias = 7, [string]$Raiz = $script:RaizSessoes)
    $info = Get-InfoWindows
    $script:DadoUsuario = $null
    $script:MotivoUsuario = $null
    $alvo = $null
    try { $alvo = Get-UsuarioAlvo -Sid $Perfil.UsuarioSid }
    catch { $script:MotivoUsuario = "usuário alvo não identificado ($($_.Exception.Message))" }
    if ($alvo) {
        try { $script:DadoUsuario = Get-DadoUsuario -Alvo $alvo -NomesI1 @(Get-Opcao $Perfil 'I1Desabilitar' | Where-Object { $_ }) }
        catch { $script:MotivoUsuario = "registro do usuário alvo não lido ($($_.Exception.Message))" }
    }
    $loja = $null

    foreach ($s in $script:ScriptsVerificados) {
        $itens = @(Get-ItemPerfil -Perfil $Perfil -Prefixo $s.Prefixo | Sort-Object -Property { [int]$_.Substring(1) } -Unique)
        if (-not $itens.Count) { continue }
        $exec = Get-EstadoExecucao -Cliente $Perfil.Cliente -Script $s.Nome -Raiz $Raiz
        if (-not $exec.Executado) {
            New-Pendente $s.Nome "$($s.Nome) não foi executado neste PC para o cliente $($Perfil.Cliente): itens $($itens -join ', ') não verificados."
            continue
        }
        if ($exec.Revertido) {
            # A reversão do Aplicativos não reinstala apps (só lista o nome a buscar na Microsoft Store).
            $estado = if ($s.Nome -eq 'Aplicativos') { 'não foram reinstalados: reinstalar pela Microsoft Store (lista na sessão de reversão)' } else { 'voltaram ao estado original' }
            New-Pendente $s.Nome "$($s.Nome) foi revertido (sessão de $($exec.Data.ToString('dd/MM/yyyy HH:mm'))): itens $($itens -join ', ') $estado."
            continue
        }
        if ($s.Nome -eq 'Aplicativos' -and $null -eq $loja) { $loja = Test-LojaDisponivel }
        foreach ($id in $itens) {
            Invoke-Checagem -Item $id -Acao {
                switch ($s.Nome) {
                    'Manutencao' { Test-ItemManutencao -Id $id -Perfil $Perfil -Info $info }
                    'Aplicativos' { Test-ItemAplicativo -Id $id -Perfil $Perfil -Loja $loja }
                    'Inicializacao' { Test-ItemInicializacao -Id $id -Perfil $Perfil -Info $info }
                    'VisualEnergia' { Test-ItemVisualEnergia -Id $id -Perfil $Perfil -Info $info }
                    'Limpeza' { Test-ItemLimpeza -Id $id -IdadeMinimaDias $IdadeMinimaDias }
                }
            }
        }
    }
}

function Format-Verificacao {
    <# Mensagem em dois blocos, em linguagem simples. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Resultados, [Parameter(Mandatory)]$Perfil, [string]$Usuario)
    $ok = @($Resultados | Where-Object { $_.Alterado })
    $pend = @($Resultados | Where-Object { -not $_.Alterado })
    $linha = { param($r) $c = if ($r.Confianca -in 'média', 'baixa') { " (confiança $($r.Confianca))" } else { '' }; "  [$($r.Item)] $($r.Texto)$c" }
    $saida = New-Object System.Collections.Generic.List[string]
    $saida.Add('Verificação final da otimização')
    $saida.Add("Cliente: $($Perfil.Cliente)   Computador: $env:COMPUTERNAME   Data: $((Get-Date).ToString('dd/MM/yyyy HH:mm'))")
    if ($Usuario) { $saida.Add("Usuário alvo: $Usuario") }
    $saida.Add('')
    $saida.Add("1. ALTERADO ($($ok.Count))")
    if ($ok.Count) { foreach ($r in $ok) { $saida.Add((& $linha $r)) } } else { $saida.Add('  Nenhum item confirmado no sistema.') }
    $saida.Add('')
    $saida.Add("2. NÃO ALTERADO OU COM ERRO ($($pend.Count))")
    if ($pend.Count) { foreach ($r in $pend) { $saida.Add((& $linha $r)) } } else { $saida.Add('  Nada pendente: tudo o que foi aprovado está aplicado.') }
    $saida.Add('')
    $saida.Add('Itens sem indicação de confiança foram conferidos direto no sistema (confiança alta).')
    $saida.Add('"Não verificável" quer dizer que não há como confirmar com segurança; não significa que falhou.')
    $saida.ToArray()
}

function Invoke-Verificacao {
    param([string]$Perfil, [int]$IdadeMinimaDias, [string]$Relatorio)
    if (-not (Test-Administrador)) { throw 'Execute como administrador: a verificação lê pacotes de todos os usuários, componentes do Windows e o registro do usuário alvo.' }
    $p = Import-PerfilCliente -Caminho $Perfil
    $resultados = @(Get-ResultadoVerificacao -Perfil $p -IdadeMinimaDias $IdadeMinimaDias)
    $usuario = $null
    try {
        $sid = if ($p.UsuarioSid) { $p.UsuarioSid } else { (Get-UsuarioAlvo).Sid }
        $usuario = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value
    }
    catch { Write-Verbose "Nome do usuário alvo não resolvido: $($_.Exception.Message)" }
    $texto = Format-Verificacao -Resultados $resultados -Perfil $p -Usuario $usuario
    if ($Relatorio) { [IO.File]::WriteAllLines($Relatorio, $texto, (New-Object Text.UTF8Encoding $true)) }
    $texto
}

# Permite carregar as funções com dot-source (testes) sem executar.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Verificacao -Perfil $Perfil -IdadeMinimaDias $IdadeMinimaDias -Relatorio $Relatorio
}

#endregion
