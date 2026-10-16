# nvidia-cache-cleanup

Limpeza automática dos instaladores de driver antigos que o **NVIDIA app** acumula no disco C: do Windows.

## O problema

Toda vez que o NVIDIA app baixa um driver novo, ele guarda o instalador (~700 MB) **e** uma cópia descompactada dele, e nunca apaga nenhum dos dois. Depois de um ano e pouco isso passa fácil de **100 GB** em:

```
C:\ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts
├── grd\                      ← instaladores Game Ready (um por versão)
│   └── post-processing\      ← cópia descompactada de cada versão (o grosso do espaço)
└── crd\                      ← instaladores Studio
    └── post-processing\
```

Esses arquivos só servem para *instalar* o driver. O driver em uso fica no DriverStore do Windows e não depende dessa pasta.

### Você tem o problema?

Rode no PowerShell:

```powershell
"{0:N1} GB" -f ((Get-ChildItem "$env:ProgramData\NVIDIA Corporation\NVIDIA app\UpdateFramework\ota-artifacts" -Recurse -Force -File | Measure-Object Length -Sum).Sum / 1GB)
```

Se aparecer bem mais que 3 GB, vale a pena instalar.

## O que o script apaga e o que ele mantém

| Apaga | Mantém |
|---|---|
| Instaladores antigos em `grd\` e `crd\` | O pacote mais recente que contém um instalador (para você conseguir atualizar sem baixar de novo) |
| As cópias descompactadas correspondentes em `post-processing\` | Tudo o que foi modificado nos últimos 3 dias (pode ser um download em andamento) |
| | Links (junctions/symlinks), que nunca são tocados |
| | Qualquer coisa fora de `ota-artifacts` (driver instalado, configurações, NVIDIA app) |

Além disso:
- se algum instalador da NVIDIA estiver rodando, o script não faz nada;
- tudo fica registrado em log: `C:\ProgramData\NvidiaCacheCleanup\logs\nvidia-cache-cleanup.log`.

## Instalação

1. Baixe o repositório (**Code → Download ZIP**) e extraia, ou use `git clone`.
2. Abra o **PowerShell como Administrador** dentro da pasta extraída.
3. (Opcional, recomendado) Veja o que seria apagado, sem apagar nada. O resultado só aparece na tela, nenhum arquivo é criado:

   ```powershell
   Get-ChildItem -Recurse *.ps1 | Unblock-File
   powershell -ExecutionPolicy Bypass -File .\src\NvidiaCacheCleanup.ps1 -DryRun
   ```

4. Instale a tarefa agendada:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\src\Install.ps1
   ```

   Isso copia o script para `C:\ProgramData\NvidiaCacheCleanup` e cria a tarefa **NvidiaCacheCleanup**. Ela roda como SYSTEM a cada 4 semanas, no domingo ao meio-dia, ou assim que o PC ligar, se ele estiver desligado nesse horário.

5. Para limpar **agora**, sem esperar o agendamento:

   ```powershell
   Start-ScheduledTask -TaskName NvidiaCacheCleanup
   Get-Content C:\ProgramData\NvidiaCacheCleanup\logs\nvidia-cache-cleanup.log -Tail 20
   ```

### Opções do instalador

| Parâmetro | Padrão | Descrição |
|---|---|---|
| `-WeeksInterval` | `4` | De quantas em quantas semanas rodar (1 a 52) |
| `-TaskName` | `NvidiaCacheCleanup` | Nome da tarefa agendada |
| `-InstallDir` | `C:\ProgramData\NvidiaCacheCleanup` | Onde o script e os logs ficam. Precisa ser uma pasta nova ou de uma instalação anterior |
| `-Uninstall` | — | Remove a tarefa e os arquivos da ferramenta (outros arquivos na pasta são preservados) |

## Desinstalação

```powershell
powershell -ExecutionPolicy Bypass -File .\src\Install.ps1 -Uninstall
```

## Segurança

A tarefa roda como SYSTEM. Por isso o instalador cria a pasta `C:\ProgramData\NvidiaCacheCleanup` já restrita: só SYSTEM e Administradores podem alterá-la, e usuários comuns só podem ler. Assim, nenhum programa sem privilégio consegue trocar o script por outro e ganhar acesso total à máquina.

O instalador **recusa** a instalação quando a pasta já existe e:
- pode ser alterada por usuários comuns (alguém pode tê-la preparado para um ataque);
- é um link (junction/symlink);
- contém arquivos que não são desta ferramenta.

Nesse caso, apague a pasta como Administrador e rode o instalador de novo.

Se usar um `-InstallDir` diferente do padrão, escolha um lugar cuja **pasta-pai** também não possa ser alterada por usuários comuns. Quem pode alterar a pasta-pai consegue renomear a pasta da ferramenta e colocar outra no lugar. O padrão (`C:\ProgramData`) é seguro.

## Desenvolvimento

O projeto usa testes com Pester 5, lint com PSScriptAnalyzer e exige cobertura mínima de 80%:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Os testes de integração criam e removem uma tarefa agendada real, então rode-os num PowerShell como Administrador. O CI (GitHub Actions) roda a mesma suíte no Windows PowerShell 5.1 e no PowerShell 7.
