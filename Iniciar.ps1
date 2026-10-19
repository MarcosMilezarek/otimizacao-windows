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
$script:CommitIniciar = '0000000000000000000000000000000000000000'
$script:ArquivosIniciar = [ordered]@{
    'src/Menu.ps1' = '0000000000000000000000000000000000000000000000000000000000000000'
    'perfis/exemplo.psd1' = '0000000000000000000000000000000000000000000000000000000000000000'
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
