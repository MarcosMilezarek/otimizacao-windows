<#
.SYNOPSIS
    Geração do perfil do cliente pelo Menu (opção Novo perfil). Carregado pelo Menu com dot-source; não executa nada sozinho.

.DESCRIPTION
    Pergunta o cliente e o usuário alvo, mostra o catálogo por script sem nada marcado, lê da máquina as listas dos itens
    I1, I4, I9, I10 e A2 com o mesmo filtro que o script aplica, pergunta as opções só dos itens marcados, mostra o
    resumo e grava C:\ProgramData\Otimizacao\perfis\<Cliente>.psd1 (UTF-8 com BOM), relido por Import-PerfilCliente.

    O que altera: só grava o arquivo do perfil. O que se perde: nada. Reversão: apagar o arquivo.
    Nenhum dado sai da máquina.
#>

Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1') -Force

#region Catálogo e gravação

# Textos resumidos do cabeçalho de ajuda de cada script (fonte única: o script; nada além do que está lá).
$script:CatalogoPerfil = @(
    @{ Id = 'M1'; Script = 'Manutencao'; Texto = 'Verifica a imagem do Windows (DISM ScanHealth).'; Perda = 'Disco e CPU ocupados por vários minutos; com reparo aprovado, consome banda de internet (Windows Update).' }
    @{ Id = 'M2'; Script = 'Manutencao'; Texto = 'Verifica os arquivos de sistema (sfc /verifyonly).'; Perda = 'Disco e CPU ocupados por vários minutos.' }
    @{ Id = 'M3'; Script = 'Manutencao'; Texto = 'Verifica o sistema de arquivos dos volumes fixos (Repair-Volume -Scan).'; Perda = 'Disco e CPU ocupados por vários minutos.' }
    @{ Id = 'M4'; Script = 'Manutencao'; Texto = 'Garante o TRIM do NTFS ligado quando há SSD.'; Perda = 'Nada (padrão do Windows).' }
    @{ Id = 'M8'; Script = 'Manutencao'; Texto = 'Horário ativo do Windows Update por política.'; Perda = 'O usuário não muda mais o horário ativo em Configurações ("gerenciado pela organização") e o ajuste automático do horário ativo é desligado.' }
    @{ Id = 'A1'; Script = 'Aplicativos'; Texto = 'Remove apps de consumo da lista base (Clipchamp, Notícias, Clima, Solitaire, Xbox, jogos de fábrica etc.).'; Perda = 'Os apps removidos, a gravação de tela Win+G (Game Bar) e o app Xbox; reinstalação manual pela Microsoft Store.'; Aviso = 'Aprovar A1 aprova a lista base inteira.' }
    @{ Id = 'A2'; Script = 'Aplicativos'; Texto = 'Remove programas do fabricante escolhidos (Appx e MSI; EXE fica para remoção manual).'; Perda = 'Os programas removidos; reinstalação manual pela Microsoft Store (Appx) ou pelo instalador do fabricante (MSI).'; Opcao = 'A2Remover' }
    @{ Id = 'A3'; Script = 'Aplicativos'; Texto = 'OneDrive não é removido (para tirá-lo da inicialização, use o I1).'; Perda = 'Nada: informativo.'; Informativo = $true }
    @{ Id = 'A4'; Script = 'Aplicativos'; Texto = 'Remove o Teams pessoal do Windows 11 (Chat). O Teams novo nunca é tocado.'; Perda = 'O Chat do Windows 11; reinstalação pela Microsoft Store.' }
    @{ Id = 'I1'; Script = 'Inicializacao'; Texto = 'Desabilita entradas de inicialização escolhidas (como o Gerenciador de Tarefas).'; Perda = 'O programa não inicia sozinho.'; Opcao = 'I1Desabilitar' }
    @{ Id = 'I2'; Script = 'Inicializacao'; Texto = 'Edge sem aceleração de inicialização e sem execução em segundo plano.'; Perda = 'O Edge fica cerca de 1 s mais lento para abrir.' }
    @{ Id = 'I3'; Script = 'Inicializacao'; Texto = 'Chrome sem execução em segundo plano.'; Perda = 'Notificações com o app fechado.' }
    @{ Id = 'I4'; Script = 'Inicializacao'; Texto = 'Nega execução em segundo plano aos apps da Store escolhidos.'; Perda = 'Notificações com o app fechado.'; Opcao = 'I4NegarSegundoPlano' }
    @{ Id = 'I5'; Script = 'Inicializacao'; Texto = 'Widgets desligados (Windows 11). Pulado com o driver UCPD ativo.'; Perda = 'O painel de widgets.' }
    @{ Id = 'I6'; Script = 'Inicializacao'; Texto = 'Remove o app Microsoft Copilot de consumidor (não toca no Microsoft 365 Copilot).'; Perda = 'O app Copilot; volta só reinstalando pela Microsoft Store.' }
    @{ Id = 'I7'; Script = 'Inicializacao'; Texto = 'Sugestões da web desligadas na caixa de busca (confiança baixa: conferir no cliente).'; Perda = 'Resultados da web no Iniciar (se tiver efeito).' }
    @{ Id = 'I8'; Script = 'Inicializacao'; Texto = 'Gravação em segundo plano do Game Bar desligada.'; Perda = 'A gravação do Game Bar.' }
    @{ Id = 'I9'; Script = 'Inicializacao'; Texto = 'Desabilita tarefas agendadas de terceiros escolhidas.'; Perda = 'A tarefa não inicia sozinha.'; Opcao = 'I9Tarefas' }
    @{ Id = 'I10'; Script = 'Inicializacao'; Texto = 'Tipo de início de serviços de terceiros escolhidos (Manual ou Desativado).'; Perda = 'O serviço não inicia sozinho (vale após reiniciar).'; Opcao = 'I10Servicos' }
    @{ Id = 'I11'; Script = 'Inicializacao'; Texto = 'Sugestões de terceiros desligadas (no Enterprise e Education, também experiências de consumidor).'; Perda = 'Sugestões e dicas.' }
    @{ Id = 'I12'; Script = 'Inicializacao'; Texto = 'Recall sem snapshots e Click to Do desligado (só PCs Copilot+).'; Perda = 'Recall e Click to Do.' }
    @{ Id = 'V1'; Script = 'VisualEnergia'; Texto = 'Animações desligadas (mantém suavização de fontes, miniaturas e sombras).'; Perda = 'Animações.' }
    @{ Id = 'V2'; Script = 'VisualEnergia'; Texto = 'Transparência desligada.'; Perda = 'Transparência.' }
    @{ Id = 'V3'; Script = 'VisualEnergia'; Texto = 'Plano de energia Desempenho máximo (alternativa em Modern Standby).'; Perda = 'Mais consumo de energia e temperatura.'; Aviso = 'Em notebook reduz a autonomia da bateria.' }
    @{ Id = 'V4'; Script = 'VisualEnergia'; Texto = 'Modo de energia Melhor desempenho na tomada (só vale com o Equilibrado ativo).'; Perda = 'Não declarado no script; mesma natureza do V3 (mais consumo na tomada).' }
    @{ Id = 'V5'; Script = 'VisualEnergia'; Texto = 'Inicialização rápida: mantida; desliga só se escolhido.'; Perda = 'Desligada: boot a frio mais lento.' }
    @{ Id = 'V6'; Script = 'VisualEnergia'; Texto = 'Hibernação desligada, só em desktop (libera o hiberfil.sys).'; Perda = 'Hibernação e inicialização rápida (boot a frio mais lento).' }
    @{ Id = 'V7'; Script = 'VisualEnergia'; Texto = 'Num Lock ligado na inicialização.'; Perda = 'Nada.' }
    @{ Id = 'V8'; Script = 'VisualEnergia'; Texto = 'Mostrar extensões de arquivos conhecidos.'; Perda = 'Nada.' }
    @{ Id = 'V9'; Script = 'VisualEnergia'; Texto = 'Finalizar tarefa no menu da barra de tarefas (Windows 11 23H2 ou superior).'; Perda = 'Nada.' }
    @{ Id = 'V10'; Script = 'VisualEnergia'; Texto = 'Desliga o atalho das Teclas de Aderência (Shift 5 vezes).'; Perda = 'O atalho de acessibilidade (o recurso continua disponível em Configurações).' }
    @{ Id = 'L1'; Script = 'Limpeza'; Texto = 'Temporários do Windows (%windir%\Temp) antigos.'; Perda = 'Arquivos temporários apagados, sem reversão.' }
    @{ Id = 'L2'; Script = 'Limpeza'; Texto = 'Temporários de todos os perfis de usuário antigos.'; Perda = 'Arquivos temporários apagados, sem reversão.' }
    @{ Id = 'L3'; Script = 'Limpeza'; Texto = 'Cache do Chrome e do Edge (nunca cookies, senhas, histórico ou sessões).'; Perda = 'Caches apagados, sem reversão; primeiras páginas mais lentas até o cache se refazer.' }
    @{ Id = 'L4'; Script = 'Limpeza'; Texto = 'Cache de download do Windows Update.'; Perda = 'Arquivos apagados, sem reversão; o Windows Update baixa de novo o que estiver pendente.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L5'; Script = 'Limpeza'; Texto = 'Lixeira de todos os usuários.'; Perda = 'O conteúdo da Lixeira, sem reversão.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L6'; Script = 'Limpeza'; Texto = 'Windows.old (Limpeza de Disco).'; Perda = 'A opção de voltar à versão anterior do Windows.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L7'; Script = 'Limpeza'; Texto = 'Limpeza de componentes (DISM StartComponentCleanup, nunca ResetBase).'; Perda = 'Desinstalar atualizações já substituídas.'; Aviso = 'Exige aprovação específica do cliente.' }
    @{ Id = 'L8'; Script = 'Limpeza'; Texto = 'HDD: desfragmenta. SSD: garante a otimização agendada (TRIM).'; Perda = 'Nada.' }
    @{ Id = 'L9'; Script = 'Limpeza'; Texto = 'Sensor de Armazenamento ligado para temporários (Lixeira e Downloads nunca).'; Perda = 'Nada.' }
)

function Get-CatalogoPerfil {
    <# Itens do catálogo na ordem de execução dos scripts: Id, Script, Texto, Perda, Aviso, Opcao, Informativo. #>
    foreach ($i in $script:CatalogoPerfil) {
        [pscustomobject]@{
            Id = $i.Id; Script = $i.Script; Texto = $i.Texto; Perda = $i.Perda
            Aviso = $i['Aviso']; Opcao = $i['Opcao']; Informativo = [bool]$i['Informativo']
        }
    }
}

function ConvertFrom-Selecao {
    <# IDs ou números (1 = primeiro de Validos), separados por espaço ou vírgula, com faixas n-m. Devolve na ordem de Validos. #>
    [OutputType([string[]])]
    param([AllowEmptyString()][string]$Texto, [Parameter(Mandatory)][string[]]$Validos)
    $escolhidos = New-Object System.Collections.Generic.HashSet[string]
    foreach ($t in @($Texto -split '[\s,;]+' | Where-Object { $_ })) {
        # Até 4 dígitos (nenhuma lista chega a 10000 itens); limites conferidos antes de montar a faixa.
        $faixa = [regex]::Match($t, '^(\d{1,4})-(\d{1,4})$')
        $limites = $null
        if ($faixa.Success) { $limites = @([int]$faixa.Groups[1].Value, [int]$faixa.Groups[2].Value) }
        elseif ($t -match '^\d{1,4}$') { $limites = @([int]$t, [int]$t) }
        if ($null -ne $limites) {
            if (@($limites | Where-Object { $_ -lt 1 -or $_ -gt $Validos.Count }).Count) { throw [ArgumentException]"Opção '$t' fora da lista (1 a $($Validos.Count))." }
            foreach ($n in $limites[0]..$limites[1]) { [void]$escolhidos.Add($Validos[$n - 1]) }
            continue
        }
        $id = @($Validos | Where-Object { $_ -eq $t })
        if (-not $id.Count) { throw [ArgumentException]"Opção '$t' não existe na lista." }
        [void]$escolhidos.Add($id[0])
    }
    $Validos | Where-Object { $escolhidos.Contains($_) }
}

function ConvertTo-LiteralPerfil {
    <# Valor em sintaxe de arquivo de dados .psd1: string com aspas simples escapadas, número, booleano, lista ou tabela. #>
    param($Valor, [string]$Recuo = '')
    if ($null -eq $Valor) { return '$null' }
    if ($Valor -is [bool]) { return $(if ($Valor) { '$true' } else { '$false' }) }
    if ($Valor -is [int] -or $Valor -is [long]) { return [string]$Valor }
    # Escape oficial do PowerShell: dobra também os apóstrofos tipográficos (U+2018 a U+201B), que ele trata como aspas.
    if ($Valor -is [string]) { return "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Valor) + "'" }
    if ($Valor -is [Collections.IDictionary]) {
        if (-not $Valor.Count) { return '@{}' }
        $interno = "$Recuo    "
        $linhas = foreach ($k in @($Valor.Keys | Sort-Object)) { '{0}{1} = {2}' -f $interno, (ConvertTo-LiteralPerfil ([string]$k)), (ConvertTo-LiteralPerfil $Valor[$k] $interno) }
        return "@{`r`n" + ($linhas -join "`r`n") + "`r`n$Recuo}"
    }
    if ($Valor -is [Collections.IEnumerable]) { return '@(' + ((@($Valor) | ForEach-Object { ConvertTo-LiteralPerfil $_ $Recuo }) -join ', ') + ')' }
    throw "Tipo não suportado no perfil: $($Valor.GetType().FullName)"
}

function ConvertTo-TextoPerfil {
    <# Texto do .psd1 no formato de perfis\exemplo.psd1. Dados: Cliente, UsuarioSid, Aplicar, Opcoes. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Dados)
    $opcoes = if ($Dados.Opcoes) { $Dados.Opcoes } else { @{} }
    $protegidos = [ordered]@{ Aplicativos = @(); Inicializacao = @(); Servicos = @(); Tarefas = @() }
    @(
        "# Perfil de cliente gerado pelo Menu (Novo perfil) em $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Apenas dados."
        '@{'
        "    Cliente    = $(ConvertTo-LiteralPerfil ([string]$Dados.Cliente))"
        "    UsuarioSid = $(ConvertTo-LiteralPerfil ([string]$Dados.UsuarioSid))"
        "    Aplicar    = @($((@($Dados.Aplicar) | ForEach-Object { ConvertTo-LiteralPerfil ([string]$_) }) -join ', '))"
        '    Pular      = @()'
        "    Protegidos = $(ConvertTo-LiteralPerfil $protegidos '    ')"
        "    Opcoes     = $(ConvertTo-LiteralPerfil $opcoes '    ')"
        '}'
        ''
    ) -join "`r`n"
}

function Save-PerfilGerado {
    <# Grava <Pasta>\<Cliente>.psd1 em UTF-8 com BOM e relê com Import-PerfilCliente; não sobrescreve sem -Force. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Dados, [Parameter(Mandatory)][string]$Pasta, [switch]$Force)
    if ([string]$Dados.Cliente -notmatch '^[\w.-]{1,60}$') { throw 'Cliente aceita apenas letras, números, ponto, hífen e sublinhado (até 60).' }
    $arquivo = Join-Path $Pasta "$($Dados.Cliente).psd1"
    if ((Test-Path -LiteralPath $arquivo) -and -not $Force) { throw "Já existe um perfil para $($Dados.Cliente): $arquivo" }
    if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }
    [IO.File]::WriteAllText($arquivo, (ConvertTo-TextoPerfil -Dados $Dados), (New-Object Text.UTF8Encoding $true))
    try { Import-PerfilCliente -Caminho $arquivo | Out-Null }
    catch { Remove-Item -LiteralPath $arquivo -Force -ErrorAction SilentlyContinue; throw }
    $arquivo
}

#endregion

#region Listas da máquina (I1, I4, I9, I10, A2)

# As funções de leitura e filtro vêm dos próprios scripts, para a lista mostrar só o que o script aceita na aplicação.
# Cada script é carregado num módulo dinâmico (as funções auxiliares dele não vazam e Get-Opcao, presente nos dois, não colide).
foreach ($c in @(
        @{ Nome = 'Otimizacao.Leitura.Inicializacao'; Arquivo = 'Inicializacao.ps1'; Funcoes = 'Get-FonteInicializacao', 'Test-ComponenteWindows', 'Get-InicioServico', 'Get-ExecutavelComando' }
        @{ Nome = 'Otimizacao.Leitura.Aplicativos'; Arquivo = 'Aplicativos.ps1'; Funcoes = 'Get-ProgramaMaquina', 'Get-MotivoProibido' }
    )) {
    New-Module -Name $c.Nome -ArgumentList (Join-Path $PSScriptRoot $c.Arquivo), $c.Funcoes -ScriptBlock {
        param($Arquivo, $Funcoes)
        . $Arquivo -Perfil 'nao-usado.psd1'
        Export-ModuleMember -Function $Funcoes
    } | Import-Module -Force
}
# Os scripts reimportam o módulo comum com -Force, o que o retira desta sessão: importar de novo, sem -Force.
Import-Module (Join-Path $PSScriptRoot 'Otimizacao.Comum.psm1')

function Get-CandidatoI1 {
    <# Entradas de inicialização da máquina e do usuário alvo que o I1 aceita (sem componentes do Windows). #>
    param([Parameter(Mandatory)]$Alvo)
    $entradas = @(Get-FonteInicializacao -Raiz 'Registry::HKEY_LOCAL_MACHINE' -Escopo Maquina)
    $entradas += @(Invoke-NoHiveUsuario -Sid $Alvo.Sid -Perfil $Alvo.Perfil -ScriptBlock {
            param($raiz)
            Get-FonteInicializacao -Raiz $raiz -Escopo Usuario -PerfilUsuario $Alvo.Perfil
        })
    $entradas | Where-Object { -not (Test-ComponenteWindows $_.Comando) } | Sort-Object -Property Nome -Unique |
        ForEach-Object { [pscustomobject]@{ Nome = $_.Nome; Origem = $_.Origem; Comando = $_.Comando } }
}

function Get-CandidatoI4 {
    <# Apps da Store do usuário alvo com Package Family Name no formato que o I4 aceita. #>
    param([Parameter(Mandatory)]$Alvo)
    Get-AppxPackage -User $Alvo.Sid -ErrorAction Stop |
        Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage -and -not $_.NonRemovable -and [string]$_.SignatureKind -ne 'System' -and
            $_.PackageFamilyName -match '^[A-Za-z0-9.\-]+_[a-z0-9]{13}$' } |
        Sort-Object -Property PackageFamilyName -Unique |
        ForEach-Object { [pscustomobject]@{ Nome = (Get-NomeExibicaoAppx -Pacote $_).Nome; Pfn = $_.PackageFamilyName } } |
        Sort-Object -Property Nome
}

function Get-EmpresaExecutavel {
    <# Empresa nas propriedades de versão do executável, ou $null. #>
    param([string]$Caminho)
    if (-not $Caminho -or -not (Test-Path -LiteralPath $Caminho -PathType Leaf)) { return $null }
    (Get-Item -LiteralPath $Caminho).VersionInfo.CompanyName
}

function Test-ProgramaMicrosoft {
    <#
        Verdadeiro para programa do Windows (%windir%) ou da Microsoft fora dele (Defender em ProgramData, Edge Update).
        Mais restrito que o I9 e o I10, que só recusam %windir% e \Microsoft\: o Defender é intocável (CLAUDE.md).
    #>
    param([string]$Comando)
    if (Test-ComponenteWindows $Comando) { return $true }
    [string](Get-EmpresaExecutavel (Get-ExecutavelComando $Comando)) -like 'Microsoft*'
}

function Get-CandidatoI9 {
    <#
        Tarefas agendadas fora de \Microsoft\, não desabilitadas, que executam um programa (handler COM, típico do Windows,
        fica de fora) e nenhum programa do Windows ou da Microsoft.
    #>
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and [string]$_.State -ne 'Disabled' } |
        Where-Object {
            $exes = @(@($_.Actions) | Where-Object { $_ -and $_.PSObject.Properties['Execute'] -and $_.Execute } | ForEach-Object { $_.Execute })
            $exes.Count -and -not @($exes | Where-Object { Test-ProgramaMicrosoft $_ }).Count
        } |
        ForEach-Object { [pscustomobject]@{ Caminho = $_.TaskPath + $_.TaskName; Estado = [string]$_.State } } |
        Sort-Object -Property Caminho
}

function Get-CandidatoI10 {
    <# Serviços Win32 de terceiros (nem do Windows nem da Microsoft) com início automático ou manual, como o I10 exige. #>
    $inicio = @{ 2 = 'Automático'; 3 = 'Manual' }
    foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
        $i = Get-InicioServico $s.Name
        if (-not $i -or -not ($i.Tipo -band 0x30) -or -not $inicio.ContainsKey($i.Start) -or (Test-ProgramaMicrosoft $i.ImagePath)) { continue }
        [pscustomobject]@{ Nome = $s.Name; Exibicao = $s.DisplayName; Inicio = $inicio[$i.Start] }
    }
}

function Get-UsuarioLocal {
    <# Perfis de usuário locais não especiais: Sid, Nome (DOMINIO\usuario, ou o SID se não resolver) e Perfil. #>
    Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special = False' | ForEach-Object {
        $nome = try { ([Security.Principal.SecurityIdentifier]$_.SID).Translate([Security.Principal.NTAccount]).Value } catch { $_.SID }
        [pscustomobject]@{ Sid = $_.SID; Nome = $nome; Perfil = $_.LocalPath }
    } | Sort-Object -Property Nome
}

function Get-CandidatoA2 {
    <#
        Programas da máquina que o A2 aceita remover: sem Microsoft, sem ferramentas de driver e BIOS, sem os nunca
        removidos, sem Appx NonRemovable ou do sistema (o Remove-PacoteAppx recusa) e sem programa de fabricante vazio
        com nome ou Id da Microsoft (componentes do Windows sem fabricante no registro).
    #>
    $sistema = @(try { Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object { $_.NonRemovable -or [string]$_.SignatureKind -eq 'System' } | ForEach-Object { $_.Name } }
        catch { Write-Warning "A2: não foi possível ler os pacotes Appx de todos os usuários ($($_.Exception.Message))." })
    Get-ProgramaMaquina | Where-Object {
        -not (Get-MotivoProibido -Programa $_ -A2) -and -not ($_.Tipo -eq 'Appx' -and $sistema -contains $_.Id) -and
        -not (-not $_.Fabricante -and ($_.Nome -like 'Microsoft*' -or $_.Id -like 'Microsoft*'))
    } | Sort-Object -Property Nome |
        ForEach-Object { [pscustomobject]@{ Nome = $_.Nome; Fabricante = $_.Fabricante; Versao = $_.Versao; Tipo = $_.Tipo; Id = $_.Id } }
}

#endregion

#region Novo perfil (interativo)

function Read-EntradaPerfil {
    <# Único ponto de leitura do teclado (substituído nos testes). #>
    param([Parameter(Mandatory)][string]$Pergunta)
    Read-Host -Prompt $Pergunta
}

function Read-RespostaPerfil {
    <# Resposta sem espaços nas pontas; '0' cancela o Novo perfil (exceto onde 0 é valor válido, como as horas do M8). #>
    param([Parameter(Mandatory)][string]$Pergunta, [switch]$ZeroValido)
    $r = ([string](Read-EntradaPerfil -Pergunta $Pergunta)).Trim()
    if ($r -eq '0' -and -not $ZeroValido) { throw [OperationCanceledException]'Novo perfil cancelado.' }
    $r
}

function Read-SimNao {
    param([Parameter(Mandatory)][string]$Pergunta)
    while ($true) {
        $r = Read-RespostaPerfil "$Pergunta (S/N)"
        if ($r -match '^[sS]$') { return $true }
        if ($r -match '^[nN]$') { return $false }
    }
}

function Read-Selecao {
    <# Pergunta até a resposta ser uma seleção válida (ConvertFrom-Selecao); Enter vazio = nenhum. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interativo: mensagem só para a tela.')]
    param([Parameter(Mandatory)][string]$Pergunta, [Parameter(Mandatory)][string[]]$Validos)
    while ($true) {
        $r = Read-RespostaPerfil $Pergunta
        try { return @(ConvertFrom-Selecao -Texto $r -Validos $Validos) }
        catch [ArgumentException] { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}

function Read-HoraM8 {
    <# Início e fim do horário ativo: horas 0 a 23 e intervalo de 1 a 18 h, mesma regra do Manutencao. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interativo: mensagem só para a tela.')]
    param()
    while ($true) {
        $ini = Read-RespostaPerfil 'M8: hora de início do horário ativo (0 a 23)' -ZeroValido
        $fim = Read-RespostaPerfil 'M8: hora de fim do horário ativo (0 a 23)' -ZeroValido
        if ($ini -match '^\d{1,2}$' -and $fim -match '^\d{1,2}$' -and [int]$ini -le 23 -and [int]$fim -le 23) {
            $duracao = ([int]$fim - [int]$ini + 24) % 24
            if ($duracao -ge 1 -and $duracao -le 18) { return @{ M8Inicio = [int]$ini; M8Fim = [int]$fim } }
        }
        Write-Host 'Horas de 0 a 23, com intervalo de 1 a 18 h (limite do Windows).' -ForegroundColor Red
    }
}

function Get-ListaItem {
    <# Lista lida da máquina para um item de lista: Valor (gravado no perfil) e Rotulo (mostrado). #>
    param([Parameter(Mandatory)][string]$Id, $Alvo)
    switch ($Id) {
        'I1' { Get-CandidatoI1 -Alvo $Alvo | ForEach-Object { [pscustomobject]@{ Valor = $_.Nome; Rotulo = "$($_.Nome)  [$($_.Origem)]  $($_.Comando)" } } }
        'I4' { Get-CandidatoI4 -Alvo $Alvo | ForEach-Object { [pscustomobject]@{ Valor = $_.Pfn; Rotulo = "$($_.Nome)  [$($_.Pfn)]" } } }
        'I9' { Get-CandidatoI9 | ForEach-Object { [pscustomobject]@{ Valor = $_.Caminho; Rotulo = "$($_.Caminho)  [$($_.Estado)]" } } }
        'I10' { Get-CandidatoI10 | ForEach-Object { [pscustomobject]@{ Valor = $_.Nome; Rotulo = "$($_.Exibicao) ($($_.Nome))  [$($_.Inicio)]" } } }
        'A2' { Get-CandidatoA2 | ForEach-Object { [pscustomobject]@{ Valor = $_.Id; Rotulo = "$($_.Nome) $($_.Versao)  [$($_.Fabricante), $($_.Tipo)]" } } }
    }
}

function New-PerfilInterativo {
    <#
        Monta o perfil por perguntas: cliente, usuário alvo, itens por script (nada marcado), listas lidas da máquina
        e opções só dos itens marcados, resumo e confirmação. Devolve o caminho gravado, ou $null se cancelado.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interativo: texto colorido só para a tela.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Grava só depois da confirmação S/N do resumo.')]
    param([Parameter(Mandatory)][string]$Pasta)
    try {
        Write-Host ''
        Write-Host 'Novo perfil (0 cancela em qualquer pergunta, exceto nas horas)' -ForegroundColor Cyan
        $sobrescrever = $false
        while ($true) {
            $cliente = Read-RespostaPerfil 'Nome do cliente (letras, números, ponto, hífen, sublinhado)'
            if ($cliente -notmatch '^[\w.-]{1,60}$') { Write-Host 'Nome inválido.' -ForegroundColor Red; continue }
            if (-not (Test-Path -LiteralPath (Join-Path $Pasta "$cliente.psd1"))) { break }
            if (Read-SimNao "Já existe perfil para $cliente. Sobrescrever?") { $sobrescrever = $true; break }
        }

        $usuarios = @(Get-UsuarioLocal)
        Write-Host ''
        Write-Host 'Usuário alvo (HKCU alterado pelos scripts):' -ForegroundColor Cyan
        Write-Host '  1. Usuário conectado no momento do fluxo'
        for ($i = 0; $i -lt $usuarios.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 2), $usuarios[$i].Nome) }
        while ($true) {
            $r = Read-RespostaPerfil 'Usuário'
            $n = 0
            if ([int]::TryParse($r, [ref]$n) -and $n -ge 1 -and $n -le $usuarios.Count + 1) { break }
        }
        $sid = if ($n -eq 1) { '' } else { $usuarios[$n - 2].Sid }

        $catalogo = @(Get-CatalogoPerfil)
        $marcados = New-Object System.Collections.Generic.List[string]
        foreach ($grupo in @($catalogo | Group-Object -Property Script | Sort-Object -Property { [array]::IndexOf(@($catalogo.Script), $_.Name) })) {
            Write-Host ''
            Write-Host $grupo.Name -ForegroundColor Cyan
            $itens = @($grupo.Group)
            for ($i = 0; $i -lt $itens.Count; $i++) {
                $it = $itens[$i]
                Write-Host ('  {0,2}. {1,-4} {2}' -f ($i + 1), $it.Id, $it.Texto)
                Write-Host ('            Perde: {0}{1}' -f $it.Perda, $(if ($it.Aviso) { "  ATENÇÃO: $($it.Aviso)" })) -ForegroundColor DarkGray
            }
            foreach ($id in Read-Selecao -Pergunta "Itens de $($grupo.Name) (números ou IDs; Enter = nenhum)" -Validos @($itens.Id)) {
                if (-not ($itens | Where-Object Id -EQ $id).Informativo) { $marcados.Add($id) }
            }
        }
        if (-not $marcados.Count) { Write-Host 'Nenhum item marcado. Nada foi gravado.' -ForegroundColor Yellow; return $null }

        $opcoes = @{}
        $rotulos = @{}
        $alvo = $null
        foreach ($it in @($catalogo | Where-Object { $_.Opcao -and $marcados.Contains($_.Id) })) {
            try {
                if ($it.Id -in 'I1', 'I4' -and -not $alvo) { $alvo = if ($sid) { Get-UsuarioAlvo -Sid $sid } else { Get-UsuarioAlvo } }
                $lista = @(Get-ListaItem -Id $it.Id -Alvo $alvo)
            }
            catch { Write-Host "$($it.Id): não foi possível ler a lista ($($_.Exception.Message)). Item desmarcado." -ForegroundColor Yellow; [void]$marcados.Remove($it.Id); continue }
            if (-not $lista.Count) { Write-Host "$($it.Id): nada encontrado nesta máquina. Item desmarcado." -ForegroundColor Yellow; [void]$marcados.Remove($it.Id); continue }
            Write-Host ''
            Write-Host "$($it.Id): $($it.Texto)" -ForegroundColor Cyan
            for ($i = 0; $i -lt $lista.Count; $i++) { Write-Host ('  {0,2}. {1}' -f ($i + 1), $lista[$i].Rotulo) }
            $escolha = @(Read-Selecao -Pergunta "Escolha para $($it.Id) (números; Enter = nenhum)" -Validos @($lista.Valor))
            if (-not $escolha.Count) { Write-Host "$($it.Id): nada escolhido. Item desmarcado." -ForegroundColor Yellow; [void]$marcados.Remove($it.Id); continue }
            # O resumo mostra o que foi escolhido pelo nome (no A2 o perfil guarda só o Id).
            $rotulos[$it.Id] = @($lista | Where-Object { $escolha -contains $_.Valor } | ForEach-Object { $_.Rotulo })
            if ($it.Id -eq 'I10') {
                $mapa = @{}
                foreach ($s in $escolha) {
                    while ($true) {
                        $t = Read-RespostaPerfil "I10: $s fica (M) Manual ou (D) Desativado?"
                        if ($t -match '^[mM]$') { $mapa[$s] = 'Manual'; break }
                        if ($t -match '^[dD]$') { $mapa[$s] = 'Disabled'; break }
                    }
                }
                $opcoes[$it.Opcao] = $mapa
                $rotulos[$it.Id] = @($lista | Where-Object { $mapa.ContainsKey($_.Valor) } | ForEach-Object { "$($_.Rotulo) = $($mapa[$_.Valor])" })
            }
            else { $opcoes[$it.Opcao] = $escolha }
        }
        if (-not $marcados.Count) { Write-Host 'Nenhum item restou marcado. Nada foi gravado.' -ForegroundColor Yellow; return $null }

        if ($marcados.Contains('M1')) { $opcoes['M1Reparar'] = Read-SimNao 'M1: reparar a imagem se a verificação achar problema (baixa pelo Windows Update)?' }
        if ($marcados.Contains('M2')) { $opcoes['M2Reparar'] = Read-SimNao 'M2: rodar sfc /scannow se a verificação achar problema?' }
        if ($marcados.Contains('M8')) { $h = Read-HoraM8; $opcoes['M8Inicio'] = $h.M8Inicio; $opcoes['M8Fim'] = $h.M8Fim }
        if ($marcados.Contains('V5')) { $opcoes['V5DesligarInicializacaoRapida'] = Read-SimNao 'V5: desligar a inicialização rápida?' }

        $aplicar = @($catalogo | Where-Object { $marcados.Contains($_.Id) } | ForEach-Object { $_.Id })
        Write-Host ''
        Write-Host "Resumo: cliente $cliente, usuário $(if ($sid) { ($usuarios | Where-Object Sid -EQ $sid).Nome } else { 'conectado no momento do fluxo' })" -ForegroundColor Cyan
        foreach ($it in @($catalogo | Where-Object { $marcados.Contains($_.Id) })) {
            Write-Host ('  {0,-4} {1}' -f $it.Id, $it.Texto)
            foreach ($r in @($rotulos[$it.Id])) { if ($r) { Write-Host "         -> $r" } }
        }
        foreach ($k in @('M1Reparar', 'M2Reparar', 'M8Inicio', 'M8Fim', 'V5DesligarInicializacaoRapida') | Where-Object { $opcoes.ContainsKey($_) }) { Write-Host "  $k = $($opcoes[$k])" }
        if (-not (Read-SimNao 'Gravar este perfil?')) { Write-Host 'Nada foi gravado.'; return $null }
        $arquivo = Save-PerfilGerado -Dados @{ Cliente = $cliente; UsuarioSid = $sid; Aplicar = $aplicar; Opcoes = $opcoes } -Pasta $Pasta -Force:$sobrescrever
        Write-Host "Perfil gravado: $arquivo" -ForegroundColor Green
        $arquivo
    }
    catch [OperationCanceledException] { Write-Host 'Novo perfil cancelado. Nada foi gravado.' -ForegroundColor Yellow; $null }
}

#endregion
