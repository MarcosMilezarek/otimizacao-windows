<#
.SYNOPSIS
    Lancador do projeto de otimizacao: baixa os scripts de um commit fixo do GitHub, confere o SHA256 de cada arquivo e
    abre o Menu.

.DESCRIPTION
    Uso, no PowerShell aberto como administrador (o comando exato de cada versao e impresso por tools\Publicar.ps1):

        [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/marcosmilezarek/otimizacao-windows/<commit>/Iniciar.ps1 | iex

    1. Aborta sem administrador, antes de baixar qualquer coisa.
    2. Baixa cada arquivo da tabela abaixo do commit indicado para C:\ProgramData\Otimizacao\app\.baixando-<sha7>,
       confere o SHA256 e so entao renomeia para C:\ProgramData\Otimizacao\app\<sha7>. Qualquer divergencia ou falha
       apaga a pasta temporaria e aborta sem executar nada. Pasta final ja integra: nao baixa de novo.
    3. Restringe C:\ProgramData\Otimizacao a SYSTEM e Administradores (Usuarios: leitura), como o Menu.
    4. Abre o Menu em processo novo com -ExecutionPolicy Bypass (vale so para esse processo).

    O que altera: cria C:\ProgramData\Otimizacao\app\<sha7>. Nao cria tarefa, servico nem atalho.
    Reversao: apagar a pasta app\<sha7>. Os scripts baixados continuam sem acesso a internet.

    Arquivo em ASCII sem BOM: o Invoke-Expression falha com o BOM no inicio do texto. Acentos das mensagens via [char].
#>

# <publicacao>
$script:RepoIniciar = 'marcosmilezarek/otimizacao-windows'
$script:CommitIniciar = '511414e2815b61fb4bd289dd94e3c1aefbec22d9'
$script:ArquivosIniciar = [ordered]@{
    'perfis/exemplo.psd1' = 'CA79948FBBC78670B05DEB49C4C2AADEE5293896C5C2C0ADB407154818D71AA1'
    'src/Aplicativos.ps1' = 'DB65C5668C42D5F9F282BEEBA072ED51E00CFA2AE9E99537AE1A7D003D57BAFC'
    'src/Coleta.ps1' = 'BABF5360FDAFC1813A65A2E47198B8AA2460257D404A7F23FBCC7FA207158EA0'
    'src/Inicializacao.ps1' = '80D6B7FB5C732F574E08C7EBFE2807BA55256311BD127132F681E90AACEE7612'
    'src/Limpeza.ps1' = '334F2562796C533442ECF80D5E62833684B22FA0E4F38C16C939841D43E64DCD'
    'src/Manutencao.ps1' = '1C31159EE86F09668209AD693126B495FBB4D0A668214367ED870B86BEEDD628'
    'src/Menu.ps1' = '55469361C7FD3DF64092D10CBDE9341AB38FA8F40ED3EE367CBA996959C38F46'
    'src/Otimizacao.Comum.psm1' = '852DE814B291EB7FA81457E1AB764C7CC9300107C846EE07F2AD70F00CA47D43'
    'src/Perfil.ps1' = 'E2EF775A6A53D4DBD57674D53ABC541435B72FC40EE59D07A3B97BDD354DCE78'
    'src/Verificacao.ps1' = 'C1D3D0FE8EA28CBB13485B91E0488F8E8C177C0DE3A6002AC5458F6CE4EEAC5C'
    'src/VisualEnergia.ps1' = '8EAA84481D887B9DF15D33FF902FD67CBFE71E390EDF2DA1EA39A34B7D967EEE'
}
# </publicacao>

function Test-AdministradorIniciar {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HashArquivoIniciar {
    param([Parameter(Mandatory)][string]$Caminho)
    (Get-FileHash -LiteralPath $Caminho -Algorithm SHA256).Hash
}

function Test-PastaIntegra {
    <# Verdadeiro se todos os arquivos da tabela existem na pasta com o SHA256 esperado. #>
    param([Parameter(Mandatory)][string]$Pasta, [Parameter(Mandatory)][Collections.IDictionary]$Arquivos)
    foreach ($rel in $Arquivos.Keys) {
        $a = Join-Path $Pasta ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $a -PathType Leaf)) { return $false }
        if ((Get-HashArquivoIniciar $a) -ne $Arquivos[$rel]) { return $false }
    }
    $true
}

function Install-ProjetoIniciar {
    <# Baixa e confere os arquivos do commit; devolve a pasta final <Raiz>\app\<sha7>. #>
    param(
        [Parameter(Mandatory)][string]$Raiz,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][Collections.IDictionary]$Arquivos
    )
    $curto = $Commit.Substring(0, 7)
    $app = Join-Path $Raiz 'app'
    $final = Join-Path $app $curto
    if ((Test-Path -LiteralPath $final) -and (Test-PastaIntegra -Pasta $final -Arquivos $Arquivos)) { return $final }
    $temp = Join-Path $app ".baixando-$curto"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        foreach ($rel in $Arquivos.Keys) {
            $destino = Join-Path $temp ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destino) -Force | Out-Null
            try { Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/$Commit/$rel" -OutFile $destino -ErrorAction Stop }
            catch { throw "Falha ao baixar ${rel}: $($_.Exception.Message)" }
            $hash = Get-HashArquivoIniciar $destino
            if ($hash -ne $Arquivos[$rel]) { throw "SHA256 divergente em $rel (esperado $($Arquivos[$rel]), recebido $hash). Nada foi executado." }
        }
        if (Test-Path -LiteralPath $final) { Remove-Item -LiteralPath $final -Recurse -Force }
        Rename-Item -LiteralPath $temp -NewName $curto
    }
    catch {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    $final
}

function Set-AcessoRestritoIniciar {
    <# Mesmo criterio do Menu (Set-AcessoRestrito): SYSTEM e Administradores com controle total, Usuarios com leitura. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pasta do proprio projeto.')]
    param([Parameter(Mandatory)][string]$Pasta)
    & "$env:windir\System32\icacls.exe" $Pasta /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls falhou em $Pasta (codigo $LASTEXITCODE)." }
}

function Start-Iniciar {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Executado so pelo comando do usuario; o Menu tem a propria simulacao.')]
    param()
    if (-not (Test-AdministradorIniciar)) {
        throw "Abra o PowerShell como administrador (bot$([char]0xE3)o direito, Executar como administrador) e repita o comando."
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $raiz = Join-Path $env:ProgramData 'Otimizacao'
    if (-not (Test-Path -LiteralPath $raiz)) { New-Item -ItemType Directory -Path $raiz -Force | Out-Null }
    Set-AcessoRestritoIniciar -Pasta $raiz
    Write-Output "Baixando a vers$([char]0xE3)o $($script:CommitIniciar.Substring(0, 7)) e conferindo SHA256..."
    $pasta = Install-ProjetoIniciar -Raiz $raiz -Repo $script:RepoIniciar -Commit $script:CommitIniciar -Arquivos $script:ArquivosIniciar
    Write-Output "Arquivos conferidos em $pasta. Abrindo o Menu."
    $menu = Join-Path $pasta 'src\Menu.ps1'
    Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-ExecutionPolicy Bypass', "-File `"$menu`"") -Wait -NoNewWindow
}

# Os testes definem $OtimizacaoIniciarSemExecutar antes do dot-source. Via iex a variavel nao existe e o lancador roda.
if (-not (Get-Variable -Name OtimizacaoIniciarSemExecutar -ValueOnly -ErrorAction SilentlyContinue)) { Start-Iniciar }
