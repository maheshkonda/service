# Recreates the work for ADO tasks 115139 (backend), 115135 (frontend) and 115140 (database) in the existing
# clones on this machine, runs the same tests and end-to-end checks, and leaves no temporary files behind.
#
# It creates a feature branch in each repository and writes every changed file from this script.
# It does NOT commit or push. Review `git status`, then commit and push yourself.
#
# Run in a regular PowerShell window (not ISE) with Docker Desktop running:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\onboarding-tasks.ps1
# Optional: -SkipTests to skip the backend and frontend test runs (the end-to-end checks always run).

param(
    [string]$WorkDir = (Join-Path $env:USERPROFILE "tto-onboarding-portal"),
    [string]$Branch = "feature/115139-115135-115140-dev-ready",
    [string]$BaseBranch = "master",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$service = Join-Path $WorkDir "tto-onboarding-portal-service"
$frontend = Join-Path $WorkDir "tto-onboarding-portal-frontend"
$serviceFolder = Join-Path $service "src\Deloitte.TTO.OnboardingPortal"
$frontendSrc = Join-Path $frontend "src"
$tempDir = Join-Path $env:TEMP ("onboarding-redo-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$nugetVolume = "onboarding-redo-nuget"
$nodeVolume = "onboarding-redo-node-modules"

function Step($m) { Write-Host "`n[STEP] $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

# docker, git and npm write progress to stderr; only the exit code decides failure (also safe in PowerShell ISE).
function Exec([scriptblock]$cmd) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $cmd 2>&1 | ForEach-Object { Write-Host "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "Command failed (exit $code): $cmd" }
}

function Capture([scriptblock]$cmd) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { $out = & $cmd 2>$null } finally { $ErrorActionPreference = $prev }
    return (($out | Out-String).Trim())
}

# Writes a file with LF line endings, UTF-8 without BOM, and one trailing newline.
function Write-RepoFile([string]$repo, [string]$relativePath, [string]$content) {
    $path = Join-Path $repo $relativePath
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $text = ($content -replace "`r`n", "`n").TrimEnd("`n") + "`n"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Remove-RepoPath([string]$repo, [string]$relativePath) {
    $path = Join-Path $repo $relativePath
    if (Test-Path $path) { Remove-Item $path -Recurse -Force }
}

function Remove-EmptyDirectories([string]$repo) {
    Get-ChildItem $repo -Recurse -Directory -Force |
        Where-Object { $_.FullName -notmatch '\\\.git(\\|$)' } |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Force) } |
        Remove-Item -Force
}

function Wait-Http([string]$url, [int]$seconds = 240) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { return $r }
        } catch { Start-Sleep -Seconds 3 }
    }
    return $null
}

function Remove-Leftovers {
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($d in (Get-ChildItem $serviceFolder -Recurse -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -in "bin", "obj" })) {
        Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($n in "node_modules", "coverage", "dist", ".angular") {
        $p = Join-Path $frontendSrc $n
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    docker volume rm $nugetVolume $nodeVolume 2>$null | Out-Null
    $ErrorActionPreference = $prev
}

# ---------------------------------------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------------------------------------
Step "Checking prerequisites"
foreach ($t in "git", "docker") {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "$t not found in PATH" }
}
if (-not (Capture { docker version --format "{{.Server.Version}}" })) {
    throw "Docker engine is not running. Start Docker Desktop, wait for 'Engine running', then rerun."
}
foreach ($repo in $service, $frontend) {
    if (-not (Test-Path (Join-Path $repo ".git"))) { throw "Repository not found: $repo" }
    $dirty = Capture { git -C $repo status --porcelain }
    if ($dirty) { throw "$repo has uncommitted changes. Commit or stash them first:`n$dirty" }
}
Ok "git and docker available, both repositories present and clean"

# ---------------------------------------------------------------------------------------------------------
# 2. Stop the current stack before its files change
# ---------------------------------------------------------------------------------------------------------
Step "Stopping the current stack"
if (Test-Path (Join-Path $service "docker-compose.yml")) {
    Push-Location $service
    try { Exec { docker compose down } } finally { Pop-Location }
}
Ok "stack stopped"

# ---------------------------------------------------------------------------------------------------------
# 3. Branches
# ---------------------------------------------------------------------------------------------------------
foreach ($repo in $service, $frontend) {
    Step "Creating $Branch in $(Split-Path $repo -Leaf)"
    Exec { git -C $repo checkout $BaseBranch }
    Exec { git -C $repo pull --ff-only }
    Exec { git -C $repo checkout -B $Branch }
}

# ---------------------------------------------------------------------------------------------------------
# 4. Backend repository: tto-onboarding-portal-service
# ---------------------------------------------------------------------------------------------------------
Step "Applying backend, database and Helm changes"
$serviceDeletes = @(
    '.dockerignore',
    'Directory.Packages.props',
    'Instructions/instruction.md',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests.sln.DotSettings',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests.slnx',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests.csproj',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/Dependencies.cs',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/TestArtifacts/dev/settings.json',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/TestArtifacts/dev/users.json',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/TestArtifacts/int/settings.json',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/TestArtifacts/int/users.json',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/TestArtifacts/local/settings.json',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/TestArtifacts/stamp/settings.json',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/Tests/DummyStep.cs',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/Tests/DummyTest.feature',
    'IntegrationTests/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests/reqnroll.json',
    'IntegrationTests/Deloitte.TTO.ruleset',
    'cleanup.ps1',
    'replace_placeholders.ps1',
    'run.bat',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/Deloitte.TTO.OnboardingPortal.ArchitectureTests.csproj',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/HandlersTests.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/MongoDbDataTests.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/MongoDbRATests.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/SDKTests.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/ServiceTests.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.ArchitectureTests/settings.json',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Contracts/Deloitte.TTO.OnboardingPortal.Contracts.csproj',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Test.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Handlers/Deloitte.TTO.OnboardingPortal.Handlers.csproj',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Handlers/Tests/TestAuthorizationPolicy.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Handlers/Tests/TestHandler.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Handlers/Tests/TestValidator.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Controllers/OnboardingController.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.RA/Deloitte.TTO.OnboardingPortal.RA.csproj',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.RA/ITestRepository.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.RA/TestRepository.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.SDK.Internal/Deloitte.TTO.OnboardingPortal.SDK.Internal.csproj',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.SDK/AssemblyAttribute.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.SDK/Constants.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.SDK/Deloitte.TTO.OnboardingPortal.SDK.csproj',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.SDK/ITestsService.cs',
    'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/UnitTest1.cs',
    'transform_devopsservicename.ps1',
    'transform_displayname.ps1',
    'transform_servicename.ps1',
    'transform_snakecasename.ps1'
)
foreach ($p in $serviceDeletes) { Remove-RepoPath $service $p }

Write-RepoFile $service '.github/copilot-instructions.md' @'
# GitHub Copilot Instructions

## Project Overview

Backend for the SDT Onboarding Portal: an ASP.NET Core Web API (.NET 10) that stores Asset and Service onboarding
requests in SQL Server. The solution is `src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.slnx`.
The Angular frontend is a separate repository, `tto-onboarding-portal-frontend`, checked out as a sibling directory.

## Solution Structure

| Project | Purpose |
| ------- | ------- |
| `Deloitte.TTO.OnboardingPortal.Host` | Web API: `Program.cs`, controllers, request/response contracts, health checks, Swagger, CORS, the graceful shutdown endpoint the SDT Helm chart calls, and the migration runner (`--migrate-only`) |
| `Deloitte.TTO.OnboardingPortal.Data` | EF Core `OnboardingPortalDbContext`, entities in the `onboarding` schema, and migrations |
| `Deloitte.TTO.OnboardingPortal.Tests` | NUnit tests that host the API in memory with SQLite |

## Conventions

* Package versions live in `src/Deloitte.TTO.OnboardingPortal/Directory.Packages.props`; `PackageReference` items have no `Version`.
* All packages are public (nuget.org). Do not add `Deloitte.TTO.*` internal packages without agreeing it with the team, because Docker Compose builds cannot restore them.
* Static analysis uses `SonarAnalyzer.CSharp` and `StyleCop.Analyzers` with `Deloitte.TTO.ruleset`; many rules are errors. Private fields start with `_`.
* Model changes need an EF Core migration (see README). `MigrationsTests` fails when one is missing.
* Migrations never run inside normal API pods in Kubernetes: Compose sets `Database__MigrateOnStartup=true`, and DEV runs a Helm hook Job with `--migrate-only`.
* The PR checker requires at least 80% line coverage.
* Secrets are never committed. Local Compose values are development-only; DEV values come from pipeline secrets into Kubernetes secrets (`src/helm/values.yaml`).
'@

Write-RepoFile $service 'docker-compose.yml' @'
# The only supported local environment for the Onboarding Portal.
# Clone tto-onboarding-portal-frontend next to this repository, then run: docker compose up --build
name: tto-onboarding-portal

services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: onboarding-sqlserver
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_PID: Developer
      # Local development value only. DEV uses a Kubernetes secret (see src/helm/values.yaml).
      MSSQL_SA_PASSWORD: "LocalDev_Passw0rd1"
    ports:
      - "1433:1433"
    volumes:
      - sqlserver-data:/var/opt/mssql
    healthcheck:
      test: /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$${MSSQL_SA_PASSWORD}" -Q "SELECT 1" -b -o /dev/null
      interval: 15s
      timeout: 10s
      retries: 20
      start_period: 60s

  backend:
    build:
      context: src/Deloitte.TTO.OnboardingPortal
      dockerfile: Deloitte.TTO.OnboardingPortal.Host/Dockerfile
      args:
        SDK_IMAGE: mcr.microsoft.com/dotnet/sdk:10.0
        ASPNET_IMAGE: mcr.microsoft.com/dotnet/aspnet:10.0
    container_name: onboarding-backend
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__OnboardingPortal: "Server=sqlserver,1433;Database=OnboardingPortal;User Id=sa;Password=LocalDev_Passw0rd1;Encrypt=True;TrustServerCertificate=True"
      # Applies EF Core migrations on startup, retrying until SQL Server accepts connections.
      Database__MigrateOnStartup: "true"
      Cors__AllowedOrigins__0: "http://localhost:4200"
    ports:
      - "5000:8080"
    depends_on:
      sqlserver:
        condition: service_started

  frontend:
    build:
      context: ../tto-onboarding-portal-frontend/src
      dockerfile: Dockerfile
      args:
        NODE_IMAGE: node:22-alpine
        NGINX_IMAGE: nginx:1.27-alpine
    container_name: onboarding-frontend
    ports:
      - "4200:4200"
    depends_on:
      - backend

volumes:
  sqlserver-data:
'@

Write-RepoFile $service 'README.md' @'
# tto-onboarding-portal-service

ASP.NET Core (.NET 10) backend for the SDT Onboarding Portal, with its SQL Server database.
The frontend lives in [tto-onboarding-portal-frontend](https://github.com/Deloitte-US-Tax/tto-onboarding-portal-frontend).

This repository owns the local environment. `docker-compose.yml` is the only supported way to run the portal locally.

## Local development

Clone both repositories as sibling directories, because Compose builds the frontend from `../tto-onboarding-portal-frontend`:

```text
<workspace>/
  tto-onboarding-portal-frontend/
  tto-onboarding-portal-service/
```

```bash
git clone https://github.com/Deloitte-US-Tax/tto-onboarding-portal-frontend.git
git clone https://github.com/Deloitte-US-Tax/tto-onboarding-portal-service.git
cd tto-onboarding-portal-service
docker compose up --build
```

Compose starts SQL Server, then the API, which applies database migrations on startup, then the Angular app.

| Component  | URL                                   |
|------------|---------------------------------------|
| Portal     | http://localhost:4200                 |
| API        | http://localhost:5000                 |
| Swagger    | http://localhost:5000/swagger         |
| Liveness   | http://localhost:5000/health          |
| Readiness  | http://localhost:5000/health/ready (includes the database) |
| SQL Server | localhost,1433, user `sa`             |

The SQL Server password and connection string are local development values defined in `docker-compose.yml`.

Stop with `docker compose down`. Add `-v` to also delete the local database volume.

## Repository layout

```text
docker-compose.yml                       Local environment (SQL Server, API, Angular app)
src/Deloitte.TTO.OnboardingPortal/       Service folder: Docker build context and the solution used by CI
  Deloitte.TTO.OnboardingPortal.slnx
  Directory.Packages.props               Central package versions
  Deloitte.TTO.OnboardingPortal.Host/    API, Dockerfile, appsettings*.json
  Deloitte.TTO.OnboardingPortal.Data/    EF Core DbContext, entities and migrations
  Deloitte.TTO.OnboardingPortal.Tests/   NUnit tests (in-memory API with SQLite)
src/helm/values.yaml                     Helm values for the SDT generic chart, including DEV SQL Server
```

## API

| Method | Route                              | Description                                   |
|--------|------------------------------------|-----------------------------------------------|
| GET    | `/api/onboarding-requests`         | Latest 100 requests, newest first             |
| GET    | `/api/onboarding-requests/{id}`    | One request, or 404                           |
| POST   | `/api/onboarding-requests`         | Create a request (`requestType`: `Asset` or `Service`, `name`, optional `description`) |

New requests start in the `Draft` status at the `Intake` stage.

## Database

- SQL Server runs in a container: a Compose service locally, and a StatefulSet with a persistent volume in DEV.
- The schema is managed with EF Core migrations in `Deloitte.TTO.OnboardingPortal.Data/Migrations`.
- Under Compose, the API applies migrations on startup (`Database__MigrateOnStartup=true`).
- In DEV, a Helm hook Job runs the API image with `--migrate-only` once per release (post-install, pre-upgrade), so API pods never migrate.

To add a migration after changing the model (from `src/Deloitte.TTO.OnboardingPortal`):

```bash
dotnet tool install --global dotnet-ef --version 10.0.13
dotnet ef migrations add <Name> --project Deloitte.TTO.OnboardingPortal.Data --startup-project Deloitte.TTO.OnboardingPortal.Data --output-dir Migrations
```

A unit test fails if the model has changes that no migration covers.

## Tests

```bash
cd src/Deloitte.TTO.OnboardingPortal
dotnet test --configuration Test --collect:"XPlat Code Coverage"
```

## CI/CD

The workflows in `.github/workflows` call the shared SDT pipelines in `devops-workflows-orchestrator`.
They need these repository variables (in addition to the organisation-level SDT variables):

| Variable                | Value                                                                     |
|-------------------------|---------------------------------------------------------------------------|
| `SERVICE_FOLDER`        | `Deloitte.TTO.OnboardingPortal`                                           |
| `HOST_PROJECT_PATH`     | `Deloitte.TTO.OnboardingPortal.Host/Deloitte.TTO.OnboardingPortal.Host.csproj` |
| `DATABASE_PROJECT_PATH` | `TBD` (EF Core migrations run from Helm, not from a DACPAC)               |
| `COMPONENT`             | `other`                                                                   |
| `KUBERNETES_POD_PORT`   | `8080`                                                                    |
| `ONBOARDING_PORTAL_FRONTEND_ORIGIN` | Frontend URL allowed by CORS, for example `https://<frontend host>` |

Secret: `ONBOARDING_SQL_SA_PASSWORD`, the DEV SQL Server `sa` password. It must meet the SQL Server password
policy and must not contain `"`, `\` or `;`.

The build also needs at least one git tag in the repository and the service registered on the
"Deployment Tool" Azure DevOps wiki page.
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Deloitte.TTO.OnboardingPortal.Data.csproj' @'
<Project Sdk="Microsoft.NET.Sdk">

	<PropertyGroup>
		<TargetFramework>net10.0</TargetFramework>
		<Nullable>enable</Nullable>
		<ImplicitUsings>enable</ImplicitUsings>
		<Configurations>Debug;Release;Test</Configurations>
		<CodeAnalysisRuleSet>..\Deloitte.TTO.ruleset</CodeAnalysisRuleSet>
	</PropertyGroup>

	<ItemGroup>
		<PackageReference Include="Microsoft.EntityFrameworkCore.SqlServer" />
		<PackageReference Include="Microsoft.EntityFrameworkCore.Design">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
		<PackageReference Include="SonarAnalyzer.CSharp">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
		<PackageReference Include="StyleCop.Analyzers">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
	</ItemGroup>

</Project>
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/DesignTimeDbContextFactory.cs' @'
using System.Diagnostics.CodeAnalysis;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace Deloitte.TTO.OnboardingPortal.Data;

/// <summary>
/// Lets <c>dotnet ef migrations add</c> build the model without starting the API host.
/// The connection string is never used to connect when generating migrations.
/// </summary>
[ExcludeFromCodeCoverage]
public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<OnboardingPortalDbContext>
{
    /// <inheritdoc />
    public OnboardingPortalDbContext CreateDbContext(string[] args)
    {
        var options = new DbContextOptionsBuilder<OnboardingPortalDbContext>()
            .UseSqlServer("Server=localhost;Database=OnboardingPortal;Integrated Security=false;TrustServerCertificate=True")
            .Options;

        return new OnboardingPortalDbContext(options);
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Entities/OnboardingRequest.cs' @'
namespace Deloitte.TTO.OnboardingPortal.Data.Entities;

/// <summary>
/// A request to onboard a new Asset or a new Service under an existing Asset.
/// </summary>
public class OnboardingRequest
{
    /// <summary>Gets or sets the request identifier.</summary>
    public Guid Id { get; set; }

    /// <summary>Gets or sets what is being onboarded.</summary>
    public OnboardingRequestType RequestType { get; set; }

    /// <summary>Gets or sets the Asset or Service name.</summary>
    public string Name { get; set; } = string.Empty;

    /// <summary>Gets or sets the free-text description supplied by the requester.</summary>
    public string? Description { get; set; }

    /// <summary>Gets or sets the overall request status.</summary>
    public OnboardingRequestStatus Status { get; set; }

    /// <summary>Gets or sets the onboarding stage the request is currently in.</summary>
    public string CurrentStage { get; set; } = string.Empty;

    /// <summary>Gets or sets who raised the request. Populated once sign-in exists.</summary>
    public string? RequestedBy { get; set; }

    /// <summary>Gets or sets when the request was created.</summary>
    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>Gets or sets when the request was last changed.</summary>
    public DateTimeOffset UpdatedAt { get; set; }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Entities/OnboardingRequestStatus.cs' @'
namespace Deloitte.TTO.OnboardingPortal.Data.Entities;

/// <summary>
/// Overall lifecycle status of an onboarding request.
/// </summary>
public enum OnboardingRequestStatus
{
    /// <summary>Created and still editable by the requester.</summary>
    Draft = 1,

    /// <summary>Submitted for onboarding.</summary>
    Submitted = 2,

    /// <summary>Being worked through the onboarding stages.</summary>
    InProgress = 3,

    /// <summary>All stages finished.</summary>
    Completed = 4,

    /// <summary>Withdrawn before completion.</summary>
    Cancelled = 5,
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Entities/OnboardingRequestType.cs' @'
namespace Deloitte.TTO.OnboardingPortal.Data.Entities;

/// <summary>
/// What an onboarding request is for.
/// </summary>
public enum OnboardingRequestType
{
    /// <summary>A new Asset (application).</summary>
    Asset = 1,

    /// <summary>A new Service under an existing Asset.</summary>
    Service = 2,
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Migrations/.editorconfig' @'
# Migrations are generated by `dotnet ef migrations add`; analyzers skip generated code.
[*.cs]
generated_code = true
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Migrations/20261014173540_InitialCreate.cs' @'
using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Deloitte.TTO.OnboardingPortal.Data.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.EnsureSchema(
                name: "onboarding");

            migrationBuilder.CreateTable(
                name: "OnboardingRequests",
                schema: "onboarding",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    RequestType = table.Column<string>(type: "nvarchar(32)", maxLength: 32, nullable: false),
                    Name = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    Description = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: true),
                    Status = table.Column<string>(type: "nvarchar(32)", maxLength: 32, nullable: false),
                    CurrentStage = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    RequestedBy = table.Column<string>(type: "nvarchar(256)", maxLength: 256, nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OnboardingRequests", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_OnboardingRequests_CreatedAt",
                schema: "onboarding",
                table: "OnboardingRequests",
                column: "CreatedAt");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "OnboardingRequests",
                schema: "onboarding");
        }
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Migrations/20261014173540_InitialCreate.Designer.cs' @'
// <auto-generated />
using System;
using Deloitte.TTO.OnboardingPortal.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

#nullable disable

namespace Deloitte.TTO.OnboardingPortal.Data.Migrations
{
    [DbContext(typeof(OnboardingPortalDbContext))]
    [Migration("20261014173540_InitialCreate")]
    partial class InitialCreate
    {
        /// <inheritdoc />
        protected override void BuildTargetModel(ModelBuilder modelBuilder)
        {
#pragma warning disable 612, 618
            modelBuilder
                .HasDefaultSchema("onboarding")
                .HasAnnotation("ProductVersion", "10.0.13")
                .HasAnnotation("Relational:MaxIdentifierLength", 128);

            SqlServerModelBuilderExtensions.UseIdentityColumns(modelBuilder);

            modelBuilder.Entity("Deloitte.TTO.OnboardingPortal.Data.Entities.OnboardingRequest", b =>
                {
                    b.Property<Guid>("Id")
                        .HasColumnType("uniqueidentifier");

                    b.Property<DateTimeOffset>("CreatedAt")
                        .HasColumnType("datetimeoffset");

                    b.Property<string>("CurrentStage")
                        .IsRequired()
                        .HasMaxLength(100)
                        .HasColumnType("nvarchar(100)");

                    b.Property<string>("Description")
                        .HasMaxLength(2000)
                        .HasColumnType("nvarchar(2000)");

                    b.Property<string>("Name")
                        .IsRequired()
                        .HasMaxLength(200)
                        .HasColumnType("nvarchar(200)");

                    b.Property<string>("RequestType")
                        .IsRequired()
                        .HasMaxLength(32)
                        .HasColumnType("nvarchar(32)");

                    b.Property<string>("RequestedBy")
                        .HasMaxLength(256)
                        .HasColumnType("nvarchar(256)");

                    b.Property<string>("Status")
                        .IsRequired()
                        .HasMaxLength(32)
                        .HasColumnType("nvarchar(32)");

                    b.Property<DateTimeOffset>("UpdatedAt")
                        .HasColumnType("datetimeoffset");

                    b.HasKey("Id");

                    b.HasIndex("CreatedAt");

                    b.ToTable("OnboardingRequests", "onboarding");
                });
#pragma warning restore 612, 618
        }
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/Migrations/OnboardingPortalDbContextModelSnapshot.cs' @'
// <auto-generated />
using System;
using Deloitte.TTO.OnboardingPortal.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

#nullable disable

namespace Deloitte.TTO.OnboardingPortal.Data.Migrations
{
    [DbContext(typeof(OnboardingPortalDbContext))]
    partial class OnboardingPortalDbContextModelSnapshot : ModelSnapshot
    {
        protected override void BuildModel(ModelBuilder modelBuilder)
        {
#pragma warning disable 612, 618
            modelBuilder
                .HasDefaultSchema("onboarding")
                .HasAnnotation("ProductVersion", "10.0.13")
                .HasAnnotation("Relational:MaxIdentifierLength", 128);

            SqlServerModelBuilderExtensions.UseIdentityColumns(modelBuilder);

            modelBuilder.Entity("Deloitte.TTO.OnboardingPortal.Data.Entities.OnboardingRequest", b =>
                {
                    b.Property<Guid>("Id")
                        .HasColumnType("uniqueidentifier");

                    b.Property<DateTimeOffset>("CreatedAt")
                        .HasColumnType("datetimeoffset");

                    b.Property<string>("CurrentStage")
                        .IsRequired()
                        .HasMaxLength(100)
                        .HasColumnType("nvarchar(100)");

                    b.Property<string>("Description")
                        .HasMaxLength(2000)
                        .HasColumnType("nvarchar(2000)");

                    b.Property<string>("Name")
                        .IsRequired()
                        .HasMaxLength(200)
                        .HasColumnType("nvarchar(200)");

                    b.Property<string>("RequestType")
                        .IsRequired()
                        .HasMaxLength(32)
                        .HasColumnType("nvarchar(32)");

                    b.Property<string>("RequestedBy")
                        .HasMaxLength(256)
                        .HasColumnType("nvarchar(256)");

                    b.Property<string>("Status")
                        .IsRequired()
                        .HasMaxLength(32)
                        .HasColumnType("nvarchar(32)");

                    b.Property<DateTimeOffset>("UpdatedAt")
                        .HasColumnType("datetimeoffset");

                    b.HasKey("Id");

                    b.HasIndex("CreatedAt");

                    b.ToTable("OnboardingRequests", "onboarding");
                });
#pragma warning restore 612, 618
        }
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Data/OnboardingPortalDbContext.cs' @'
using Deloitte.TTO.OnboardingPortal.Data.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace Deloitte.TTO.OnboardingPortal.Data;

/// <summary>
/// Entity Framework context for the Onboarding Portal SQL Server database.
/// </summary>
public class OnboardingPortalDbContext : DbContext
{
    /// <summary>Database schema that owns all portal tables.</summary>
    public const string Schema = "onboarding";

    private const int NameMaxLength = 200;
    private const int DescriptionMaxLength = 2000;
    private const int StageMaxLength = 100;
    private const int EnumMaxLength = 32;
    private const int UserMaxLength = 256;

    // Compared by name so this project does not depend on the SQLite provider package.
    private const string SqliteProviderName = "Microsoft.EntityFrameworkCore.Sqlite";

    /// <summary>
    /// Initializes a new instance of the <see cref="OnboardingPortalDbContext"/> class.
    /// </summary>
    /// <param name="options">Context options.</param>
    public OnboardingPortalDbContext(DbContextOptions<OnboardingPortalDbContext> options)
        : base(options)
    {
    }

    /// <summary>Gets the onboarding requests.</summary>
    public DbSet<OnboardingRequest> OnboardingRequests => Set<OnboardingRequest>();

    /// <inheritdoc />
    protected override void ConfigureConventions(ModelConfigurationBuilder configurationBuilder)
    {
        ArgumentNullException.ThrowIfNull(configurationBuilder);

        // SQLite (used by the unit tests) cannot order or compare DateTimeOffset natively.
        // SQL Server keeps its native datetimeoffset type.
        if (Database.ProviderName == SqliteProviderName)
        {
            configurationBuilder.Properties<DateTimeOffset>().HaveConversion<DateTimeOffsetToBinaryConverter>();
        }
    }

    /// <inheritdoc />
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        ArgumentNullException.ThrowIfNull(modelBuilder);

        modelBuilder.HasDefaultSchema(Schema);

        modelBuilder.Entity<OnboardingRequest>(entity =>
        {
            entity.ToTable("OnboardingRequests");
            entity.HasKey(r => r.Id);
            entity.Property(r => r.Id).ValueGeneratedNever();

            // Stored as text so the data stays readable in SQL and enum reordering cannot corrupt rows.
            entity.Property(r => r.RequestType).HasConversion<string>().HasMaxLength(EnumMaxLength).IsRequired();
            entity.Property(r => r.Status).HasConversion<string>().HasMaxLength(EnumMaxLength).IsRequired();

            entity.Property(r => r.Name).HasMaxLength(NameMaxLength).IsRequired();
            entity.Property(r => r.Description).HasMaxLength(DescriptionMaxLength);
            entity.Property(r => r.CurrentStage).HasMaxLength(StageMaxLength).IsRequired();
            entity.Property(r => r.RequestedBy).HasMaxLength(UserMaxLength);
            entity.Property(r => r.CreatedAt).IsRequired();
            entity.Property(r => r.UpdatedAt).IsRequired();

            entity.HasIndex(r => r.CreatedAt);
        });
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/appsettings.Development.json' @'
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "Database": {
    "MigrateOnStartup": true
  },
  "Cors": {
    "AllowedOrigins": [ "http://localhost:4200" ]
  }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/appsettings.json' @'
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore.Database.Command": "Warning"
    }
  },
  "AllowedHosts": "*",
  "ConnectionStrings": {
    "OnboardingPortal": ""
  },
  "Database": {
    "MigrateOnStartup": false,
    "MigrationMaxAttempts": 30,
    "MigrationRetryDelaySeconds": 5
  },
  "Swagger": {
    "Enabled": true
  },
  "Cors": {
    "AllowedOrigins": []
  },
  "GracefulShutdown": {
    "DrainDelaySeconds": 5
  }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/appsettings.Release.json' @'
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore": "Warning"
    }
  },
  "Database": {
    "MigrateOnStartup": false
  }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Contracts/CreateOnboardingRequest.cs' @'
using System.ComponentModel.DataAnnotations;
using Deloitte.TTO.OnboardingPortal.Data.Entities;

namespace Deloitte.TTO.OnboardingPortal.Host.Contracts;

/// <summary>
/// Body for creating an onboarding request.
/// </summary>
public sealed class CreateOnboardingRequest
{
    /// <summary>Gets or sets what is being onboarded: <c>Asset</c> or <c>Service</c>.</summary>
    [Required]
    [EnumDataType(typeof(OnboardingRequestType))]
    public OnboardingRequestType? RequestType { get; set; }

    /// <summary>Gets or sets the Asset or Service name.</summary>
    [Required(AllowEmptyStrings = false)]
    [StringLength(200)]
    public string Name { get; set; } = string.Empty;

    /// <summary>Gets or sets an optional description.</summary>
    [StringLength(2000)]
    public string? Description { get; set; }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Contracts/OnboardingRequestResponse.cs' @'
using Deloitte.TTO.OnboardingPortal.Data.Entities;

namespace Deloitte.TTO.OnboardingPortal.Host.Contracts;

/// <summary>
/// An onboarding request as returned by the API.
/// </summary>
/// <param name="Id">Request identifier.</param>
/// <param name="RequestType">What is being onboarded.</param>
/// <param name="Name">Asset or Service name.</param>
/// <param name="Description">Optional description.</param>
/// <param name="Status">Overall status.</param>
/// <param name="CurrentStage">Current onboarding stage.</param>
/// <param name="RequestedBy">Who raised the request, once sign-in exists.</param>
/// <param name="CreatedAt">Creation time.</param>
/// <param name="UpdatedAt">Last change time.</param>
public sealed record OnboardingRequestResponse(
    Guid Id,
    OnboardingRequestType RequestType,
    string Name,
    string? Description,
    OnboardingRequestStatus Status,
    string CurrentStage,
    string? RequestedBy,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    /// <summary>
    /// Maps an entity to the API shape.
    /// </summary>
    /// <param name="request">The entity.</param>
    /// <returns>The response.</returns>
    public static OnboardingRequestResponse From(OnboardingRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        return new OnboardingRequestResponse(
            request.Id,
            request.RequestType,
            request.Name,
            request.Description,
            request.Status,
            request.CurrentStage,
            request.RequestedBy,
            request.CreatedAt,
            request.UpdatedAt);
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Controllers/OnboardingRequestsController.cs' @'
using Deloitte.TTO.OnboardingPortal.Data;
using Deloitte.TTO.OnboardingPortal.Data.Entities;
using Deloitte.TTO.OnboardingPortal.Host.Contracts;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace Deloitte.TTO.OnboardingPortal.Host.Controllers;

/// <summary>
/// Creates and reads onboarding requests.
/// </summary>
[ApiController]
[Route("api/onboarding-requests")]
[Produces("application/json")]
public sealed class OnboardingRequestsController : ControllerBase
{
    /// <summary>First stage of every new request. The workflow tasks add the later stages.</summary>
    public const string InitialStage = "Intake";

    private const int MaxListSize = 100;

    private readonly OnboardingPortalDbContext _db;
    private readonly TimeProvider _timeProvider;

    /// <summary>
    /// Initializes a new instance of the <see cref="OnboardingRequestsController"/> class.
    /// </summary>
    /// <param name="db">Database context.</param>
    /// <param name="timeProvider">Clock.</param>
    public OnboardingRequestsController(OnboardingPortalDbContext db, TimeProvider timeProvider)
    {
        _db = db;
        _timeProvider = timeProvider;
    }

    /// <summary>
    /// Lists the most recent onboarding requests, newest first.
    /// </summary>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Up to 100 requests.</returns>
    [HttpGet]
    [ProducesResponseType<IReadOnlyList<OnboardingRequestResponse>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<OnboardingRequestResponse>>> ListAsync(CancellationToken cancellationToken)
    {
        var requests = await _db.OnboardingRequests
            .AsNoTracking()
            .OrderByDescending(r => r.CreatedAt)
            .Take(MaxListSize)
            .ToListAsync(cancellationToken);

        return requests.Select(OnboardingRequestResponse.From).ToList();
    }

    /// <summary>
    /// Gets one onboarding request.
    /// </summary>
    /// <param name="id">Request identifier.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>The request, or 404.</returns>
    [HttpGet("{id:guid}", Name = nameof(GetAsync))]
    [ProducesResponseType<OnboardingRequestResponse>(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<OnboardingRequestResponse>> GetAsync(Guid id, CancellationToken cancellationToken)
    {
        var request = await _db.OnboardingRequests
            .AsNoTracking()
            .SingleOrDefaultAsync(r => r.Id == id, cancellationToken);

        return request is null ? NotFound() : OnboardingRequestResponse.From(request);
    }

    /// <summary>
    /// Creates an onboarding request in the Draft status at the Intake stage.
    /// </summary>
    /// <param name="body">Request details.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>The created request.</returns>
    [HttpPost]
    [ProducesResponseType<OnboardingRequestResponse>(StatusCodes.Status201Created)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<OnboardingRequestResponse>> CreateAsync(
        [FromBody] CreateOnboardingRequest body,
        CancellationToken cancellationToken)
    {
        // [ApiController] has already rejected a missing body or failed validation with 400.
        var now = _timeProvider.GetUtcNow();
        var request = new OnboardingRequest
        {
            Id = Guid.NewGuid(),
            RequestType = body.RequestType!.Value,
            Name = body.Name.Trim(),
            Description = string.IsNullOrWhiteSpace(body.Description) ? null : body.Description.Trim(),
            Status = OnboardingRequestStatus.Draft,
            CurrentStage = InitialStage,
            CreatedAt = now,
            UpdatedAt = now,
        };

        _db.OnboardingRequests.Add(request);
        await _db.SaveChangesAsync(cancellationToken);

        return CreatedAtRoute(nameof(GetAsync), new { id = request.Id }, OnboardingRequestResponse.From(request));
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Deloitte.TTO.OnboardingPortal.Host.csproj' @'
<Project Sdk="Microsoft.NET.Sdk.Web">

	<PropertyGroup>
		<TargetFramework>net10.0</TargetFramework>
		<Nullable>enable</Nullable>
		<ImplicitUsings>enable</ImplicitUsings>
		<Configurations>Debug;Release;Test</Configurations>
		<CodeAnalysisRuleSet>..\Deloitte.TTO.ruleset</CodeAnalysisRuleSet>
		<!-- InvariantGlobalization must stay off: Microsoft.Data.SqlClient refuses to open connections in that mode. -->
	</PropertyGroup>

	<ItemGroup>
		<PackageReference Include="Microsoft.Extensions.Diagnostics.HealthChecks.EntityFrameworkCore" />
		<PackageReference Include="Swashbuckle.AspNetCore" />
		<PackageReference Include="SonarAnalyzer.CSharp">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
		<PackageReference Include="StyleCop.Analyzers">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
	</ItemGroup>

	<ItemGroup>
		<ProjectReference Include="..\Deloitte.TTO.OnboardingPortal.Data\Deloitte.TTO.OnboardingPortal.Data.csproj" />
	</ItemGroup>

	<ItemGroup>
		<InternalsVisibleTo Include="Deloitte.TTO.OnboardingPortal.Tests" />
	</ItemGroup>

</Project>
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Dockerfile' @'
# Build context is the service folder: src/Deloitte.TTO.OnboardingPortal
# (the SDT build workflow and docker-compose.yml both use it).
#
# The SDT build workflow replaces the #{...}# tokens with the approved GCI base images.
# docker compose overrides both arguments with public Microsoft images for local builds.
ARG SDK_IMAGE=#{GCI_IMAGE_SDK}#
ARG ASPNET_IMAGE=#{GCI_IMAGE_ASPNET}#

FROM ${ASPNET_IMAGE} AS base
WORKDIR /app
EXPOSE 8080

FROM ${SDK_IMAGE} AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src
COPY ["Directory.Packages.props", "."]
COPY ["Deloitte.TTO.ruleset", "."]
COPY ["Deloitte.TTO.OnboardingPortal.Host/Deloitte.TTO.OnboardingPortal.Host.csproj", "Deloitte.TTO.OnboardingPortal.Host/"]
COPY ["Deloitte.TTO.OnboardingPortal.Data/Deloitte.TTO.OnboardingPortal.Data.csproj", "Deloitte.TTO.OnboardingPortal.Data/"]
# Restored before nuget.config is copied: every package is public, so restore needs nuget.org only.
RUN dotnet restore "Deloitte.TTO.OnboardingPortal.Host/Deloitte.TTO.OnboardingPortal.Host.csproj"
COPY . .
RUN dotnet publish "Deloitte.TTO.OnboardingPortal.Host/Deloitte.TTO.OnboardingPortal.Host.csproj" \
    -c $BUILD_CONFIGURATION -o /app/publish --no-restore /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
USER app
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "Deloitte.TTO.OnboardingPortal.Host.dll"]
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Infrastructure/DatabaseMigrator.cs' @'
using Deloitte.TTO.OnboardingPortal.Data;
using Microsoft.EntityFrameworkCore;

namespace Deloitte.TTO.OnboardingPortal.Host.Infrastructure;

/// <summary>
/// Applies Entity Framework migrations, retrying while SQL Server is still starting.
/// </summary>
internal static partial class DatabaseMigrator
{
    /// <summary>Command-line argument that applies migrations and exits without serving HTTP.</summary>
    public const string MigrateOnlyArgument = "--migrate-only";

    /// <summary>Setting that applies migrations before the API starts serving (used by docker compose).</summary>
    public const string MigrateOnStartupSetting = "Database:MigrateOnStartup";

    private const string MaxAttemptsSetting = "Database:MigrationMaxAttempts";
    private const string RetryDelaySecondsSetting = "Database:MigrationRetryDelaySeconds";
    private const int DefaultMaxAttempts = 30;
    private const int DefaultRetryDelaySeconds = 5;

    /// <summary>
    /// Applies pending migrations to the configured database.
    /// </summary>
    /// <param name="services">Root service provider.</param>
    /// <param name="configuration">Application configuration.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>A task that completes when the schema is up to date.</returns>
    public static async Task MigrateDatabaseAsync(
        this IServiceProvider services,
        IConfiguration configuration,
        CancellationToken cancellationToken)
    {
        var maxAttempts = configuration.GetValue(MaxAttemptsSetting, DefaultMaxAttempts);
        var delay = TimeSpan.FromSeconds(configuration.GetValue(RetryDelaySecondsSetting, DefaultRetryDelaySeconds));
        var logger = services.GetRequiredService<ILoggerFactory>().CreateLogger(typeof(DatabaseMigrator));

        await RunWithRetryAsync(
            async token =>
            {
                await using var scope = services.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<OnboardingPortalDbContext>();
                await db.Database.MigrateAsync(token);
            },
            maxAttempts,
            delay,
            logger,
            cancellationToken);
    }

    /// <summary>
    /// Runs <paramref name="migrate"/> until it succeeds or <paramref name="maxAttempts"/> is reached.
    /// </summary>
    /// <param name="migrate">The migration action.</param>
    /// <param name="maxAttempts">Maximum number of attempts, at least 1.</param>
    /// <param name="delay">Delay between attempts.</param>
    /// <param name="logger">Logger.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>A task that completes when <paramref name="migrate"/> succeeds.</returns>
    internal static Task RunWithRetryAsync(
        Func<CancellationToken, Task> migrate,
        int maxAttempts,
        TimeSpan delay,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(migrate);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxAttempts, 1);

        return RunWithRetryCoreAsync(migrate, maxAttempts, delay, logger, cancellationToken);
    }

    private static async Task RunWithRetryCoreAsync(
        Func<CancellationToken, Task> migrate,
        int maxAttempts,
        TimeSpan delay,
        ILogger logger,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                LogApplying(logger, attempt, maxAttempts);
                await migrate(cancellationToken);
                LogApplied(logger);
                return;
            }
            catch (Exception ex) when (attempt < maxAttempts && ex is not OperationCanceledException)
            {
                LogRetrying(logger, ex, attempt, delay.TotalSeconds);
                await Task.Delay(delay, cancellationToken);
            }
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Applying database migrations, attempt {Attempt} of {MaxAttempts}")]
    private static partial void LogApplying(ILogger logger, int attempt, int maxAttempts);

    [LoggerMessage(Level = LogLevel.Information, Message = "Database migrations applied")]
    private static partial void LogApplied(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Database migration attempt {Attempt} failed, retrying in {DelaySeconds} seconds")]
    private static partial void LogRetrying(ILogger logger, Exception exception, int attempt, double delaySeconds);
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Infrastructure/GracefulShutdownEndpoint.cs' @'
using System.Security.Cryptography;
using System.Text;

namespace Deloitte.TTO.OnboardingPortal.Host.Infrastructure;

/// <summary>
/// The SDT Helm chart calls <c>GET /gracefulShutdownEndpoint/{token}</c> as the container preStop hook.
/// Answering after a short delay lets the ingress and service mesh stop routing to the pod before
/// Kubernetes sends SIGTERM, so in-flight requests are not cut off.
/// </summary>
internal static class GracefulShutdownEndpoint
{
    /// <summary>Route used by the chart's preStop hook.</summary>
    public const string Route = "/gracefulShutdownEndpoint/{token}";

    private const string TokenSetting = "GracefulShutdownAuthToken";
    private const string DrainDelaySetting = "GracefulShutdown:DrainDelaySeconds";
    private const int DefaultDrainDelaySeconds = 5;

    /// <summary>
    /// Maps the graceful shutdown endpoint.
    /// </summary>
    /// <param name="app">The endpoint route builder.</param>
    /// <returns>The same builder.</returns>
    public static IEndpointRouteBuilder MapGracefulShutdownEndpoint(this IEndpointRouteBuilder app)
    {
        app.MapGet(Route, async (string token, IConfiguration configuration, CancellationToken cancellationToken) =>
        {
            var expected = configuration[TokenSetting];
            if (string.IsNullOrEmpty(expected) || !TokensMatch(expected, token))
            {
                return Results.NotFound();
            }

            var delay = TimeSpan.FromSeconds(configuration.GetValue(DrainDelaySetting, DefaultDrainDelaySeconds));
            await Task.Delay(delay, cancellationToken);
            return Results.Ok();
        }).ExcludeFromDescription();

        return app;
    }

    private static bool TokensMatch(string expected, string actual) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(actual));
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Infrastructure/OnboardingPortalHostExtensions.cs' @'
using System.Text.Json.Serialization;
using Deloitte.TTO.OnboardingPortal.Data;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.EntityFrameworkCore;
using Microsoft.OpenApi;

namespace Deloitte.TTO.OnboardingPortal.Host.Infrastructure;

/// <summary>
/// Service registration and request pipeline for the Onboarding Portal API.
/// </summary>
internal static class OnboardingPortalHostExtensions
{
    /// <summary>Name of the SQL Server connection string.</summary>
    public const string ConnectionStringName = "OnboardingPortal";

    /// <summary>Liveness endpoint. Does not touch dependencies.</summary>
    public const string LivenessPath = "/health";

    /// <summary>Readiness endpoint. Checks that the database is reachable.</summary>
    public const string ReadinessPath = "/health/ready";

    private const string CorsPolicyName = "PortalFrontend";
    private const string ReadyTag = "ready";
    private const string SwaggerDocumentName = "v1";

    /// <summary>
    /// Loads the environment settings file that the SDT Helm chart mounts under <c>AppSettingsBasePath</c>.
    /// </summary>
    /// <param name="builder">The web application builder.</param>
    /// <returns>The same builder.</returns>
    public static WebApplicationBuilder AddMountedAppSettings(this WebApplicationBuilder builder)
    {
        ArgumentNullException.ThrowIfNull(builder);

        var basePath = builder.Configuration["AppSettingsBasePath"];
        if (!string.IsNullOrWhiteSpace(basePath))
        {
            var fileName = $"appsettings.{builder.Environment.EnvironmentName.ToLowerInvariant()}.json";
            builder.Configuration.AddJsonFile(Path.Combine(basePath, fileName), optional: true, reloadOnChange: false);

            // Re-added so container environment variables still override the mounted file.
            builder.Configuration.AddEnvironmentVariables();
        }

        return builder;
    }

    /// <summary>
    /// Registers controllers, the database context, health checks, Swagger and CORS.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="configuration">Application configuration.</param>
    /// <returns>The same service collection.</returns>
    public static IServiceCollection AddOnboardingPortal(this IServiceCollection services, IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        services
            .AddControllers()
            .AddJsonOptions(options => options.JsonSerializerOptions.Converters.Add(new JsonStringEnumConverter()));

        // The connection string may be absent when the image is started only to export Swagger in CI.
        var connectionString = configuration.GetConnectionString(ConnectionStringName);
        services.AddDbContext<OnboardingPortalDbContext>(options =>
        {
            if (string.IsNullOrWhiteSpace(connectionString))
            {
                options.UseSqlServer();
            }
            else
            {
                options.UseSqlServer(connectionString, sql => sql.EnableRetryOnFailure());
            }
        });

        services.AddSingleton(TimeProvider.System);

        services.AddHealthChecks()
            .AddDbContextCheck<OnboardingPortalDbContext>("database", tags: [ReadyTag]);

        services.AddEndpointsApiExplorer();
        services.AddSwaggerGen(options => options.SwaggerDoc(SwaggerDocumentName, new OpenApiInfo
        {
            Title = "TTO Onboarding Portal API",
            Version = SwaggerDocumentName,
            Description = "Asset and Service onboarding requests.",
        }));

        var allowedOrigins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
        services.AddCors(options => options.AddPolicy(CorsPolicyName, policy =>
        {
            if (allowedOrigins.Length > 0)
            {
                policy.WithOrigins(allowedOrigins).AllowAnyHeader().AllowAnyMethod();
            }
        }));

        return services;
    }

    /// <summary>
    /// Configures middleware and maps endpoints.
    /// </summary>
    /// <param name="app">The web application.</param>
    /// <returns>The same application.</returns>
    public static WebApplication UseOnboardingPortal(this WebApplication app)
    {
        ArgumentNullException.ThrowIfNull(app);

        // Kept on outside Development: CI exports swagger.json from the image and the
        // SDT ingress health check probes /swagger/index.html.
        if (app.Configuration.GetValue("Swagger:Enabled", defaultValue: true))
        {
            app.UseSwagger();
            app.UseSwaggerUI();
        }

        app.UseCors(CorsPolicyName);

        app.MapHealthChecks(LivenessPath, new HealthCheckOptions { Predicate = _ => false });
        app.MapHealthChecks(ReadinessPath, new HealthCheckOptions { Predicate = check => check.Tags.Contains(ReadyTag) });
        app.MapGracefulShutdownEndpoint();
        app.MapControllers();

        return app;
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Host/Program.cs' @'
using Deloitte.TTO.OnboardingPortal.Host.Infrastructure;

var builder = WebApplication.CreateBuilder(args);

builder.AddMountedAppSettings();
builder.Services.AddOnboardingPortal(builder.Configuration);

var app = builder.Build();

// DEV runs migrations once per release from a Helm hook Job using this image with --migrate-only,
// so API pods never race each other to change the schema.
if (args.Contains(DatabaseMigrator.MigrateOnlyArgument, StringComparer.OrdinalIgnoreCase))
{
    await app.Services.MigrateDatabaseAsync(app.Configuration, app.Lifetime.ApplicationStopping);
    return;
}

if (app.Configuration.GetValue<bool>(DatabaseMigrator.MigrateOnStartupSetting))
{
    await app.Services.MigrateDatabaseAsync(app.Configuration, app.Lifetime.ApplicationStopping);
}

app.UseOnboardingPortal();

await app.RunAsync();

/// <summary>
/// Entry point. Declared partial so integration tests can host the API with WebApplicationFactory.
/// </summary>
public partial class Program
{
    /// <summary>
    /// Prevents a default instance of the <see cref="Program"/> class from being created.
    /// </summary>
    protected Program()
    {
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.slnx' @'
<Solution>
  <Configurations>
    <BuildType Name="Debug" />
    <BuildType Name="Release" />
    <BuildType Name="Test" />
  </Configurations>
  <Folder Name="/Data/">
    <Project Path="Deloitte.TTO.OnboardingPortal.Data/Deloitte.TTO.OnboardingPortal.Data.csproj" />
  </Folder>
  <Folder Name="/Tests/">
    <Project Path="Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests.csproj" />
  </Folder>
  <Folder Name="/Solution Items/">
    <File Path="../../.github/copilot-instructions.md" />
    <File Path="../../docker-compose.yml" />
    <File Path="../../rules.jsonc" />
    <File Path="Directory.Packages.props" />
    <File Path="nuget.config" />
  </Folder>
  <Project Path="Deloitte.TTO.OnboardingPortal.Host/Deloitte.TTO.OnboardingPortal.Host.csproj" />
</Solution>
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/DatabaseMigratorTests.cs' @'
using Deloitte.TTO.OnboardingPortal.Data;
using Deloitte.TTO.OnboardingPortal.Host.Infrastructure;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace Deloitte.TTO.OnboardingPortal.Tests;

[TestFixture]
public sealed class DatabaseMigratorTests
{
    [Test]
    public async Task RunWithRetry_SucceedsAfterTransientFailures()
    {
        var attempts = 0;

        await DatabaseMigrator.RunWithRetryAsync(
            _ =>
            {
                attempts++;
                return attempts < 3 ? throw new InvalidOperationException("SQL Server is starting") : Task.CompletedTask;
            },
            maxAttempts: 5,
            delay: TimeSpan.Zero,
            NullLogger.Instance,
            CancellationToken.None);

        Assert.That(attempts, Is.EqualTo(3));
    }

    [Test]
    public void RunWithRetry_RethrowsAfterLastAttempt()
    {
        var attempts = 0;

        Assert.ThrowsAsync<InvalidOperationException>(() => DatabaseMigrator.RunWithRetryAsync(
            _ =>
            {
                attempts++;
                throw new InvalidOperationException("still down");
            },
            maxAttempts: 2,
            delay: TimeSpan.Zero,
            NullLogger.Instance,
            CancellationToken.None));

        Assert.That(attempts, Is.EqualTo(2));
    }

    [Test]
    public void RunWithRetry_RejectsZeroAttempts()
    {
        Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => DatabaseMigrator.RunWithRetryAsync(
            _ => Task.CompletedTask,
            maxAttempts: 0,
            delay: TimeSpan.Zero,
            NullLogger.Instance,
            CancellationToken.None));
    }

    [Test]
    public async Task MigrateDatabaseAsync_AppliesMigrations()
    {
        await using var connection = new SqliteConnection("DataSource=:memory:");
        await connection.OpenAsync();

        // The migrations target SQL Server. SQLite stores DateTimeOffset differently, so EF reports a
        // model difference that only exists in this test database.
        var services = new ServiceCollection()
            .AddLogging()
            .AddDbContext<OnboardingPortalDbContext>(options => options
                .UseSqlite(connection)
                .ConfigureWarnings(warnings => warnings.Ignore(RelationalEventId.PendingModelChangesWarning)))
            .BuildServiceProvider();
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["Database:MigrationRetryDelaySeconds"] = "0" })
            .Build();

        await services.MigrateDatabaseAsync(configuration, CancellationToken.None);

        await using var scope = services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<OnboardingPortalDbContext>();
        Assert.That(await db.Database.GetPendingMigrationsAsync(), Is.Empty);
        Assert.That(await db.Database.GetAppliedMigrationsAsync(), Is.Not.Empty);
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/Deloitte.TTO.OnboardingPortal.Tests.csproj' @'
<Project Sdk="Microsoft.NET.Sdk">

	<PropertyGroup>
		<TargetFramework>net10.0</TargetFramework>
		<ImplicitUsings>enable</ImplicitUsings>
		<Nullable>enable</Nullable>
		<IsPackable>false</IsPackable>
		<IsTestProject>true</IsTestProject>
		<Configurations>Debug;Release;Test</Configurations>
		<CodeAnalysisRuleSet>..\Deloitte.TTO.ruleset</CodeAnalysisRuleSet>
	</PropertyGroup>

	<ItemGroup>
		<PackageReference Include="coverlet.collector">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
		<PackageReference Include="Microsoft.AspNetCore.Mvc.Testing" />
		<PackageReference Include="Microsoft.EntityFrameworkCore.Sqlite" />
		<PackageReference Include="Microsoft.NET.Test.Sdk" />
		<PackageReference Include="NUnit" />
		<PackageReference Include="NUnit.Analyzers">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
		<PackageReference Include="NUnit3TestAdapter" />
		<PackageReference Include="SonarAnalyzer.CSharp">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
		<PackageReference Include="StyleCop.Analyzers">
			<PrivateAssets>all</PrivateAssets>
			<IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
		</PackageReference>
	</ItemGroup>

	<ItemGroup>
		<Using Include="NUnit.Framework" />
		<AssemblyAttribute Include="System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute" />
	</ItemGroup>

	<ItemGroup>
		<ProjectReference Include="..\Deloitte.TTO.OnboardingPortal.Host\Deloitte.TTO.OnboardingPortal.Host.csproj" />
	</ItemGroup>

</Project>
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/MigrationsTests.cs' @'
using Deloitte.TTO.OnboardingPortal.Data;
using Microsoft.EntityFrameworkCore;

namespace Deloitte.TTO.OnboardingPortal.Tests;

[TestFixture]
public sealed class MigrationsTests
{
    [Test]
    public void SqlServerModel_HasNoChangesMissingFromMigrations()
    {
        // No connection is opened: the check compares the model with the latest migration snapshot.
        var options = new DbContextOptionsBuilder<OnboardingPortalDbContext>()
            .UseSqlServer("Server=unused;Database=unused;TrustServerCertificate=True")
            .Options;
        using var db = new OnboardingPortalDbContext(options);

        Assert.That(
            db.Database.HasPendingModelChanges(),
            Is.False,
            "The model changed without a migration. Add one with dotnet ef migrations add (see README).");
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/MountedAppSettingsTests.cs' @'
using Deloitte.TTO.OnboardingPortal.Host.Infrastructure;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;

namespace Deloitte.TTO.OnboardingPortal.Tests;

[TestFixture]
public sealed class MountedAppSettingsTests
{
    private string _directory = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Directory.CreateTempSubdirectory("portal-appsettings-").FullName;
    }

    [TearDown]
    public void TearDown()
    {
        Directory.Delete(_directory, recursive: true);
    }

    [Test]
    public void AddMountedAppSettings_LoadsEnvironmentFileFromBasePath()
    {
        File.WriteAllText(Path.Combine(_directory, "appsettings.dev.json"), "{\"Portal\":{\"Marker\":\"from-mounted-file\"}}");
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = "dev" });
        builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> { ["AppSettingsBasePath"] = _directory });

        builder.AddMountedAppSettings();

        Assert.That(builder.Configuration["Portal:Marker"], Is.EqualTo("from-mounted-file"));
    }

    [Test]
    public void AddMountedAppSettings_WithoutBasePath_AddsNothing()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = "dev" });
        var sourcesBefore = builder.Configuration.Sources.Count;

        builder.AddMountedAppSettings();

        Assert.That(builder.Configuration.Sources, Has.Count.EqualTo(sourcesBefore));
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/OnboardingRequestsApiTests.cs' @'
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Deloitte.TTO.OnboardingPortal.Data.Entities;
using Deloitte.TTO.OnboardingPortal.Host.Contracts;
using Deloitte.TTO.OnboardingPortal.Host.Controllers;

namespace Deloitte.TTO.OnboardingPortal.Tests;

[TestFixture]
public sealed class OnboardingRequestsApiTests : IDisposable
{
    private const string RequestsPath = "/api/onboarding-requests";

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter() },
    };

    private PortalApiFactory _factory = null!;
    private HttpClient _client = null!;

    [SetUp]
    public void SetUp()
    {
        _factory = new PortalApiFactory();
        _client = _factory.CreateClient();
    }

    [TearDown]
    public void TearDown() => Dispose();

    public void Dispose()
    {
        _client?.Dispose();
        _factory?.Dispose();
    }

    [Test]
    public async Task Create_ThenGet_ReturnsThePersistedRequest()
    {
        var create = await _client.PostAsJsonAsync(
            RequestsPath,
            new { requestType = "Asset", name = "  Tax Engine  ", description = "New tax engine asset" },
            Json);

        Assert.That(create.StatusCode, Is.EqualTo(HttpStatusCode.Created));
        var created = await create.Content.ReadFromJsonAsync<OnboardingRequestResponse>(Json);
        Assert.That(created, Is.Not.Null);
        Assert.That(create.Headers.Location?.ToString(), Does.EndWith($"{RequestsPath}/{created!.Id}"));

        var fetched = await _client.GetFromJsonAsync<OnboardingRequestResponse>($"{RequestsPath}/{created.Id}", Json);

        Assert.That(fetched, Is.Not.Null);
        Assert.Multiple(() =>
        {
            Assert.That(fetched!.Id, Is.EqualTo(created.Id));
            Assert.That(fetched.RequestType, Is.EqualTo(OnboardingRequestType.Asset));
            Assert.That(fetched.Name, Is.EqualTo("Tax Engine"));
            Assert.That(fetched.Description, Is.EqualTo("New tax engine asset"));
            Assert.That(fetched.Status, Is.EqualTo(OnboardingRequestStatus.Draft));
            Assert.That(fetched.CurrentStage, Is.EqualTo(OnboardingRequestsController.InitialStage));
            Assert.That(fetched.CreatedAt, Is.EqualTo(fetched.UpdatedAt));
        });
    }

    [Test]
    public async Task Create_WithBlankDescription_StoresNoDescription()
    {
        var create = await _client.PostAsJsonAsync(RequestsPath, new { requestType = "Service", name = "Billing", description = "   " }, Json);
        var created = await create.Content.ReadFromJsonAsync<OnboardingRequestResponse>(Json);

        Assert.That(created!.Description, Is.Null);
    }

    [Test]
    public async Task List_ReturnsRequestsNewestFirst()
    {
        await _client.PostAsJsonAsync(RequestsPath, new { requestType = "Asset", name = "First" }, Json);
        await Task.Delay(TimeSpan.FromMilliseconds(20));
        await _client.PostAsJsonAsync(RequestsPath, new { requestType = "Service", name = "Second" }, Json);

        var list = await _client.GetFromJsonAsync<List<OnboardingRequestResponse>>(RequestsPath, Json);

        Assert.That(list!.Select(r => r.Name), Is.EqualTo(new[] { "Second", "First" }));
    }

    [Test]
    public async Task Get_UnknownId_Returns404()
    {
        var response = await _client.GetAsync(Url($"{RequestsPath}/{Guid.NewGuid()}"));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [TestCase("{\"name\":\"No type\"}")]
    [TestCase("{\"requestType\":\"Asset\"}")]
    [TestCase("{\"requestType\":\"Asset\",\"name\":\"\"}")]
    [TestCase("{\"requestType\":\"Unknown\",\"name\":\"Bad type\"}")]
    public async Task Create_WithInvalidBody_Returns400(string body)
    {
        using var content = new StringContent(body, System.Text.Encoding.UTF8, "application/json");

        var response = await _client.PostAsync(Url(RequestsPath), content);

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [TestCase("/health")]
    [TestCase("/health/ready")]
    public async Task HealthEndpoints_ReturnHealthy(string path)
    {
        var response = await _client.GetAsync(Url(path));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await response.Content.ReadAsStringAsync(), Is.EqualTo("Healthy"));
    }

    [Test]
    public async Task SwaggerDocument_IsServed()
    {
        var response = await _client.GetAsync(Url("/swagger/v1/swagger.json"));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain(RequestsPath));
    }

    [Test]
    public async Task GracefulShutdown_WithValidToken_Returns200()
    {
        var response = await _client.GetAsync(Url($"/gracefulShutdownEndpoint/{PortalApiFactory.ShutdownToken}"));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task GracefulShutdown_WithWrongToken_Returns404()
    {
        var response = await _client.GetAsync(Url("/gracefulShutdownEndpoint/not-the-token"));

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [Test]
    public async Task Cors_AllowsConfiguredFrontendOrigin()
    {
        using var preflight = new HttpRequestMessage(HttpMethod.Options, Url(RequestsPath));
        preflight.Headers.Add("Origin", PortalApiFactory.FrontendOrigin);
        preflight.Headers.Add("Access-Control-Request-Method", "POST");

        var response = await _client.SendAsync(preflight);

        Assert.That(response.Headers.TryGetValues("Access-Control-Allow-Origin", out var origins), Is.True);
        Assert.That(origins, Is.EqualTo(new[] { PortalApiFactory.FrontendOrigin }));
    }

    private static Uri Url(string path) => new(path, UriKind.Relative);
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Deloitte.TTO.OnboardingPortal.Tests/PortalApiFactory.cs' @'
using Deloitte.TTO.OnboardingPortal.Data;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Deloitte.TTO.OnboardingPortal.Tests;

/// <summary>
/// Hosts the real API in memory with an in-memory SQLite database in place of SQL Server.
/// </summary>
internal sealed class PortalApiFactory : WebApplicationFactory<Program>
{
    public const string ShutdownToken = "test-shutdown-token";
    public const string FrontendOrigin = "http://localhost:4200";

    private readonly SqliteConnection _connection = new("DataSource=:memory:");

    public PortalApiFactory()
    {
        // The in-memory database lives as long as this connection stays open.
        _connection.Open();
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.UseSetting("ConnectionStrings:OnboardingPortal", string.Empty);
        builder.UseSetting("Database:MigrateOnStartup", "false");
        builder.UseSetting("GracefulShutdownAuthToken", ShutdownToken);
        builder.UseSetting("GracefulShutdown:DrainDelaySeconds", "0");
        builder.UseSetting("Cors:AllowedOrigins:0", FrontendOrigin);

        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<DbContextOptions<OnboardingPortalDbContext>>();
            services.RemoveAll<IDbContextOptionsConfiguration<OnboardingPortalDbContext>>();
            services.AddDbContext<OnboardingPortalDbContext>(options => options.UseSqlite(_connection));

            using var provider = services.BuildServiceProvider();
            using var scope = provider.CreateScope();
            scope.ServiceProvider.GetRequiredService<OnboardingPortalDbContext>().Database.EnsureCreated();
        });
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            _connection.Dispose();
        }
    }
}
'@

Write-RepoFile $service 'src/Deloitte.TTO.OnboardingPortal/Directory.Packages.props' @'
<Project>
  <!--
    Lives in the service folder rather than the repository root so that the Docker build context
    (src/Deloitte.TTO.OnboardingPortal) contains it both in CI and in docker compose. The shared
    build workflow only copies a root-level file here when this one is missing.
  -->
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
    <!-- Lets the PackageVersion entries below also lift vulnerable transitive dependencies. -->
    <CentralPackageTransitivePinningEnabled>true</CentralPackageTransitivePinningEnabled>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="coverlet.collector" Version="8.0.1" />
    <PackageVersion Include="Microsoft.AspNetCore.Mvc.Testing" Version="10.0.13" />
    <PackageVersion Include="Microsoft.EntityFrameworkCore.Design" Version="10.0.13" />
    <PackageVersion Include="Microsoft.EntityFrameworkCore.Sqlite" Version="10.0.13" />
    <PackageVersion Include="Microsoft.EntityFrameworkCore.SqlServer" Version="10.0.13" />
    <PackageVersion Include="Microsoft.Extensions.Diagnostics.HealthChecks.EntityFrameworkCore" Version="10.0.13" />
    <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="18.8.1" />
    <PackageVersion Include="NUnit" Version="4.6.1" />
    <PackageVersion Include="NUnit.Analyzers" Version="4.14.0" />
    <PackageVersion Include="NUnit3TestAdapter" Version="6.2.0" />
    <PackageVersion Include="SonarAnalyzer.CSharp" Version="10.30.0.144632" />
    <PackageVersion Include="StyleCop.Analyzers" Version="1.2.0-beta.556" />
    <PackageVersion Include="Swashbuckle.AspNetCore" Version="10.3.0" />
    <!-- Transitive via Microsoft.Data.SqlClient; 9.0.11 has GHSA-846f-f764-76mx (high) and GHSA-2fmv-rv2c-59x7. -->
    <PackageVersion Include="System.Security.Cryptography.Pkcs" Version="10.0.13" />
  </ItemGroup>
</Project>
'@

Write-RepoFile $service 'src/helm/values.yaml' @'
# Applied after the generic chart's values-tto.yaml and values-tto-<env>.yaml, then src/helm/values-<env>.yaml.
# See https://github.com/Deloitte-US-Tax/generic-chart/blob/main/values-tto.yaml
# #{NAME}# tokens are replaced by the DEPLOY SERVICE workflow from repository/environment variables and secrets.

deployment:
  enabled: true
  replicas: 2

# The chart's DEV defaults enable KEDA with an external scaler on port 9090 that only the TTO ServiceHost serves.
keda:
  enabled: false

terminationGracePeriodSeconds: 60

mainContainer:
  imagePullPolicy: IfNotPresent
  containerPorts:
    - name: http-main
      containerPort: 8080
      protocol: TCP
  env:
    - name: ASPNETCORE_URLS
      value: "http://+:8080"
    - name: ASPNETCORE_ENVIRONMENT
      value: "#{APPSETTINGS_ENVIRONMENT}#"
    - name: GracefulShutdownAuthToken
      value: "#{GITHUB_SHA}#"
    - name: Cors__AllowedOrigins__0
      value: "#{ONBOARDING_PORTAL_FRONTEND_ORIGIN}#"
  # Replaces the chart's default list (service discovery, identity authority, Contrast), which this API does not use.
  extraEnv:
    - name: AppSettingsBasePath
      value: /etc/config/appsettings
  secretEnv:
    - name: ConnectionStrings__OnboardingPortal
      secret: "#{DEPLOYMENT_NAME}#-sql"
      key: connection-string
  livenessProbe:
    enabled: true
    type: httpGet
    port: 8080
    path: /health
    initialDelaySeconds: 10
    periodSeconds: 20
    timeoutSeconds: 3
    failureThreshold: 3
  # Not /health/ready: on the first install Helm waits for these pods before the post-install migration
  # Job creates the database, so a database-dependent readiness probe would never pass.
  readinessProbe:
    enabled: true
    type: httpGet
    port: 8080
    path: /health
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 5
    failureThreshold: 3
  startupProbe:
    enabled: true
    type: httpGet
    port: 8080
    path: /health
    initialDelaySeconds: 2
    periodSeconds: 5
    timeoutSeconds: 3
    failureThreshold: 24
  lifecycle:
    preStop:
      httpGet:
        port: 8080
        path: gracefulShutdownEndpoint/#{GITHUB_SHA}#

service:
  type: ClusterIP
  servicePorts:
    - name: http-main
      port: 80
      protocol: TCP
      targetPort: 8080

ingress:
  enabled: true

# SQL Server for DEV (task 115140). Runs in the portal namespace as a StatefulSet with a persistent volume.
# DEV is non-production: Developer edition, no automated backups, no high availability. Data survives pod
# restarts and redeploys, but is lost if the PersistentVolumeClaim or the namespace is deleted.
onboardingSql:
  image: mcr.microsoft.com/mssql/server:2022-latest
  database: OnboardingPortal
  storageSize: 20Gi
  storageClassName: ""            # empty = cluster default
  # GitHub secret, replaced at deploy time and never committed. Must not contain ", \ or ;
  saPassword: "#{ONBOARDING_SQL_SA_PASSWORD}#"
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi

customManifests:
  enabled: true
  body: |
    {{- $fullname := include "chart.fullname" . }}
    {{- $sql := .Values.onboardingSql }}
    apiVersion: v1
    kind: Secret
    metadata:
      name: {{ $fullname }}-sql
      labels:
        {{- include "chart.labels" . | nindent 4 }}
    type: Opaque
    stringData:
      sa-password: {{ $sql.saPassword | quote }}
      connection-string: {{ printf "Server=%s-sql,1433;Database=%s;User Id=sa;Password=%s;Encrypt=True;TrustServerCertificate=True" $fullname $sql.database $sql.saPassword | quote }}
    ---
    apiVersion: v1
    kind: Service
    metadata:
      name: {{ $fullname }}-sql
      labels:
        {{- include "chart.labels" . | nindent 4 }}
    spec:
      type: ClusterIP
      selector:
        app.kubernetes.io/name: {{ $fullname }}-sql
        app.kubernetes.io/instance: {{ .Release.Name }}
      ports:
        - name: tcp-sql
          port: 1433
          targetPort: tcp-sql
    ---
    apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: {{ $fullname }}-sql
      labels:
        {{- include "chart.labels" . | nindent 4 }}
    spec:
      serviceName: {{ $fullname }}-sql
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: {{ $fullname }}-sql
          app.kubernetes.io/instance: {{ .Release.Name }}
      template:
        metadata:
          # Distinct labels so the API Service, PeerAuthentication and KEDA never select SQL Server pods.
          labels:
            app.kubernetes.io/name: {{ $fullname }}-sql
            app.kubernetes.io/instance: {{ .Release.Name }}
          annotations:
            # Plain TCP from the API; the Job below also runs without a sidecar.
            sidecar.istio.io/inject: "false"
        spec:
          securityContext:
            fsGroup: 10001
          {{- with .Values.affinity }}
          affinity:
            {{- toYaml . | nindent 8 }}
          {{- end }}
          containers:
            - name: mssql
              image: {{ $sql.image }}
              ports:
                - name: tcp-sql
                  containerPort: 1433
              env:
                - name: ACCEPT_EULA
                  value: "Y"
                - name: MSSQL_PID
                  value: Developer
                - name: MSSQL_SA_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: {{ $fullname }}-sql
                      key: sa-password
              volumeMounts:
                - name: data
                  mountPath: /var/opt/mssql
              readinessProbe:
                tcpSocket:
                  port: tcp-sql
                initialDelaySeconds: 20
                periodSeconds: 10
              livenessProbe:
                tcpSocket:
                  port: tcp-sql
                initialDelaySeconds: 60
                periodSeconds: 20
                failureThreshold: 6
              resources:
                {{- toYaml $sql.resources | nindent 16 }}
      volumeClaimTemplates:
        - metadata:
            name: data
          spec:
            accessModes:
              - ReadWriteOnce
            {{- if $sql.storageClassName }}
            storageClassName: {{ $sql.storageClassName }}
            {{- end }}
            resources:
              requests:
                storage: {{ $sql.storageSize }}
    ---
    # Applies EF Core migrations once per release, not in every API pod.
    # post-install (not pre-install): on the first install the SQL Server StatefulSet must exist first.
    # pre-upgrade: later releases migrate the existing database before new API pods roll out.
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: {{ $fullname }}-migrate
      labels:
        {{- include "chart.labels" . | nindent 4 }}
      annotations:
        helm.sh/hook: post-install,pre-upgrade
        helm.sh/hook-weight: "0"
        helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 900
      template:
        metadata:
          annotations:
            # A mesh sidecar would keep the Job pod running after the migration finishes.
            sidecar.istio.io/inject: "false"
        spec:
          restartPolicy: Never
          {{- with .Values.imagePullSecrets }}
          imagePullSecrets:
            {{- range . }}
            - name: {{ . }}
            {{- end }}
          {{- end }}
          {{- with .Values.affinity }}
          affinity:
            {{- toYaml . | nindent 8 }}
          {{- end }}
          containers:
            - name: migrate
              image: {{ .Values.mainContainer.image }}
              args: ["--migrate-only"]
              env:
                - name: ASPNETCORE_ENVIRONMENT
                  value: "#{APPSETTINGS_ENVIRONMENT}#"
                - name: Database__MigrationMaxAttempts
                  value: "60"
                - name: ConnectionStrings__OnboardingPortal
                  valueFrom:
                    secretKeyRef:
                      name: {{ $fullname }}-sql
                      key: connection-string
'@

Remove-EmptyDirectories $service
Ok "backend repository updated"

# ---------------------------------------------------------------------------------------------------------
# 5. Frontend repository: tto-onboarding-portal-frontend
# ---------------------------------------------------------------------------------------------------------
Step "Applying frontend changes (Angular workspace moves into src/)"
# The only binary file moves as-is.
$oldIcon = Join-Path $frontend "public\favicon.ico"
$newIcon = Join-Path $frontend "src\public\favicon.ico"
if (Test-Path $oldIcon) {
    New-Item -ItemType Directory -Force -Path (Split-Path $newIcon -Parent) | Out-Null
    Move-Item $oldIcon $newIcon -Force
}

$frontendDeletes = @(
    '.dockerignore',
    '.editorconfig',
    'Dockerfile',
    'angular.json',
    'nginx.conf',
    'package-lock.json',
    'package.json',
    'src/app/app.config.ts',
    'src/app/app.html',
    'src/app/app.routes.ts',
    'src/app/app.scss',
    'src/app/app.spec.ts',
    'src/app/app.ts',
    'src/index.html',
    'src/main.ts',
    'src/styles.scss',
    'tsconfig.app.json',
    'tsconfig.json',
    'tsconfig.spec.json'
)
foreach ($p in $frontendDeletes) { Remove-RepoPath $frontend $p }

Write-RepoFile $frontend '.github/workflows/tto_pr_checkers.yml' @'
name: PR CHECKERS

on:
  pull_request:
    types: [opened, reopened, edited, synchronize]
    branches:
      - master
      - main
  workflow_dispatch:

concurrency:
  group: tto-pr-checkers-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  PR-Checkers:
    uses: Deloitte-US-Tax/devops-workflows-orchestrator/.github/workflows/orchestrator-pr-checker.yml@master
    secrets: inherit
'@

Write-RepoFile $frontend '.github/workflows/tto_service_build.yml' @'
name: BUILD SERVICE
on:
  push:
    branches:
      - master
  workflow_dispatch:

jobs:
  Build:
    uses: Deloitte-US-Tax/devops-workflows-orchestrator/.github/workflows/orchestrator-build.yml@master
    with:
      service_folder: ${{ vars.SERVICE_FOLDER }}
      host_project_path: ${{ vars.HOST_PROJECT_PATH }}
      database_project_path: ${{ vars.DATABASE_PROJECT_PATH }}
    secrets: inherit
'@

Write-RepoFile $frontend '.github/workflows/tto_service_release.yml' @'
name: DEPLOY SERVICE
run-name: DEPLOY SERVICE to ${{ inputs.environment }}
concurrency:
  group: ${{ github.workflow }}-${{ inputs.environment }}-${{ github.ref_name }}
  cancel-in-progress: true
on:
  workflow_dispatch:
    inputs:
      environment:
        description: "Target Environment"
        required: true
        type: choice
        options:
          - DEV
      predeployment:
        description: "Run Pre-deployment steps"
        required: true
        type: boolean
        default: true
      deployment:
        description: "Run Deployment steps"
        required: true
        type: boolean
        default: true
      postdeployment:
        description: "Run Post-deployment steps"
        required: true
        type: boolean
        default: true
      integrationtests:
        description: "Run Integration Tests"
        required: true
        type: boolean
        default: false

jobs:
  Deploy:
    uses: Deloitte-US-Tax/devops-workflows-orchestrator/.github/workflows/orchestrator-deploy.yml@master
    with:
      environment: ${{ inputs.environment }}
      build_workflow_name: ${{ vars.BUILD_WORKFLOW_NAME }}
      run_predeployment: ${{ inputs.predeployment }}
      run_deployment: ${{ inputs.deployment }}
      run_postdeployment: ${{ inputs.postdeployment }}
      run_integration_tests: ${{ inputs.integrationtests }}
    secrets: inherit
'@

Write-RepoFile $frontend '.gitignore' @'
# See https://docs.github.com/get-started/getting-started-with-git/ignoring-files for more about ignoring files.
# The Angular workspace lives in src/, so these patterns are not anchored to the repository root.

# Compiled output
dist/
tmp/
out-tsc/
bazel-out/

# Node
node_modules/
npm-debug.log
yarn-error.log

# IDEs and editors
.idea/
.project
.classpath
.c9/
*.launch
.settings/
*.sublime-workspace

# Visual Studio Code
.vscode/*
!.vscode/settings.json
!.vscode/tasks.json
!.vscode/launch.json
!.vscode/extensions.json
.history/*

# Miscellaneous
.angular/cache
.sass-cache/
connect.lock
coverage/
libpeerconnection.log
testem.log
typings/
__screenshots__/

# System files
.DS_Store
Thumbs.db
'@

Write-RepoFile $frontend 'README.md' @'
# tto-onboarding-portal-frontend

Angular 20 frontend for the SDT Onboarding Portal. The backend lives in
[tto-onboarding-portal-service](https://github.com/Deloitte-US-Tax/tto-onboarding-portal-service).

## Local development

The local environment is controlled only by Docker Compose in `tto-onboarding-portal-service`.
Clone both repositories as sibling directories:

```text
<workspace>/
  tto-onboarding-portal-frontend/
  tto-onboarding-portal-service/
```

```bash
git clone https://github.com/Deloitte-US-Tax/tto-onboarding-portal-frontend.git
git clone https://github.com/Deloitte-US-Tax/tto-onboarding-portal-service.git
cd tto-onboarding-portal-service
docker compose up --build
```

The portal is served at http://localhost:4200 and calls the API at http://localhost:5000.

Stop with `docker compose down` from `tto-onboarding-portal-service`.

## Repository layout

The Angular workspace is in `src/`, which is the folder the shared SDT build, lint and test workflows use.

```text
src/
  package.json, angular.json            Angular workspace
  src/app/                              Application code
  public/assets/env/base-settings.json  Runtime settings used by Docker Compose
  Dockerfile, default.conf              nginx image serving the app on port 4200
  PipelineArtifacts/ui-config/<ENV>/    Runtime settings for each deployed environment
  helm/values.yaml                      Helm values for the SDT generic chart
```

## Runtime configuration

The app reads `assets/env/base-settings.json` before it starts:

```json
{ "appName": "tto-onboarding-portal", "environment": "local", "apiBaseUrl": "http://localhost:5000" }
```

The image contains the local values. In a deployed environment, the DEPLOY SERVICE workflow publishes
`src/PipelineArtifacts/ui-config/<ENV>/base-settings.json` as a ConfigMap and mounts it over that file,
so the same image runs everywhere.

## Scripts

Run from `src/`:

| Command            | What it does                                  |
|--------------------|-----------------------------------------------|
| `npm start`        | Development server on http://localhost:4200   |
| `npm run build`    | Production build into `dist/`                 |
| `npm run lint:all` | ESLint (used by the PR checker)               |
| `npm run test:all` | Jest with coverage (used by the PR checker)   |

## CI/CD

The workflows in `.github/workflows` call the shared SDT pipelines. Repository variables:

| Variable            | Value                                         |
|---------------------|-----------------------------------------------|
| `SERVICE_FOLDER`    | `.`                                           |
| `HOST_PROJECT_PATH` | `./`                                          |
| `DATABASE_PROJECT_PATH` | `TBD`                                     |
| `COMPONENT`         | `front`                                       |
| `APIM_GENERATION`   | `false`                                       |
| `HOSTNAME_FRONTEND` | The portal's DEV host name                    |

`src/PipelineArtifacts/ui-config/DEV/base-settings.json` assumes the API is reachable at
`https://aks-ingress.dev.ustax.deloitte.com/onboarding-portal-service`. Update it if the service path differs.
'@

Write-RepoFile $frontend 'src/.dockerignore' @'
node_modules
dist
coverage
out-tsc
.angular
helm
PipelineArtifacts
Dockerfile
.dockerignore
'@

Write-RepoFile $frontend 'src/.editorconfig' @'
# Editor configuration, see https://editorconfig.org
root = true

[*]
charset = utf-8
indent_style = space
indent_size = 2
insert_final_newline = true
trim_trailing_whitespace = true

[*.ts]
quote_type = single
ij_typescript_use_double_quotes = false

[*.md]
max_line_length = off
trim_trailing_whitespace = false
'@

Write-RepoFile $frontend 'src/.npmrc_ci' @'
# Read by the SDT lint and test workflows (copied to .npmrc). This app only uses public packages.
registry=https://registry.npmjs.org/
'@

Write-RepoFile $frontend 'src/angular.json' @'
{
  "$schema": "./node_modules/@angular/cli/lib/config/schema.json",
  "version": 1,
  "cli": {
    "analytics": false
  },
  "newProjectRoot": "projects",
  "projects": {
    "tto-onboarding-portal-frontend": {
      "projectType": "application",
      "schematics": {
        "@schematics/angular:component": {
          "style": "scss"
        }
      },
      "root": "",
      "sourceRoot": "src",
      "prefix": "app",
      "architect": {
        "build": {
          "builder": "@angular/build:application",
          "options": {
            "browser": "src/main.ts",
            "polyfills": [
              "zone.js"
            ],
            "tsConfig": "tsconfig.app.json",
            "inlineStyleLanguage": "scss",
            "assets": [
              {
                "glob": "**/*",
                "input": "public"
              }
            ],
            "styles": [
              "src/styles.scss"
            ]
          },
          "configurations": {
            "production": {
              "budgets": [
                {
                  "type": "initial",
                  "maximumWarning": "500kB",
                  "maximumError": "1MB"
                },
                {
                  "type": "anyComponentStyle",
                  "maximumWarning": "4kB",
                  "maximumError": "8kB"
                }
              ],
              "outputHashing": "all"
            },
            "development": {
              "optimization": false,
              "extractLicenses": false,
              "sourceMap": true
            }
          },
          "defaultConfiguration": "production"
        },
        "serve": {
          "builder": "@angular/build:dev-server",
          "configurations": {
            "production": {
              "buildTarget": "tto-onboarding-portal-frontend:build:production"
            },
            "development": {
              "buildTarget": "tto-onboarding-portal-frontend:build:development"
            }
          },
          "defaultConfiguration": "development"
        },
        "extract-i18n": {
          "builder": "@angular/build:extract-i18n"
        }
      }
    }
  }
}
'@

Write-RepoFile $frontend 'src/default.conf' @'
server {
    listen 4200;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Runtime settings are replaced per environment by a ConfigMap; never cache them.
    location /assets/env/ {
        add_header Cache-Control "no-store";
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
'@

Write-RepoFile $frontend 'src/Dockerfile' @'
# Build context is this folder (src). The SDT build workflow replaces the #{...}# tokens with the
# approved GCI base images; docker compose in tto-onboarding-portal-service passes public images.
ARG NODE_IMAGE=#{GCI_IMAGE_NODE}#
ARG NGINX_IMAGE=#{GCI_IMAGE_NGINX}#

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npx ng build --configuration production

FROM ${NGINX_IMAGE}
# Runs as the unprivileged nginx user on port 4200, like the other SDT frontends.
RUN touch /var/run/nginx.pid \
    && chown -R nginx:nginx /var/cache/nginx /var/run/nginx.pid
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/tto-onboarding-portal-frontend/browser/ /usr/share/nginx/html/
USER nginx
EXPOSE 4200
CMD ["nginx", "-g", "daemon off;"]
'@

Write-RepoFile $frontend 'src/eslint.config.js' @'
// @ts-check
const eslint = require('@eslint/js');
const tseslint = require('typescript-eslint');
const angular = require('angular-eslint');

module.exports = tseslint.config(
  {
    ignores: ['dist/**', 'coverage/**', '.angular/**', 'node_modules/**', 'out-tsc/**'],
  },
  {
    files: ['**/*.ts'],
    extends: [
      eslint.configs.recommended,
      ...tseslint.configs.recommended,
      ...tseslint.configs.stylistic,
      ...angular.configs.tsRecommended,
    ],
    processor: angular.processInlineTemplates,
    rules: {
      '@angular-eslint/directive-selector': [
        'error',
        { type: 'attribute', prefix: 'app', style: 'camelCase' },
      ],
      '@angular-eslint/component-selector': [
        'error',
        { type: 'element', prefix: 'app', style: 'kebab-case' },
      ],
    },
  },
  {
    files: ['**/*.html'],
    extends: [...angular.configs.templateRecommended, ...angular.configs.templateAccessibility],
  },
);
'@

Write-RepoFile $frontend 'src/helm/values.yaml' @'
# Applied after the generic chart's values-tto-front.yaml and values-tto-front-<env>.yaml.
# See https://github.com/Deloitte-US-Tax/generic-chart/blob/main/values-tto-front.yaml
deployment:
  enabled: true
  replicas: 2

# The chart's DEV defaults enable KEDA with an external scaler on port 9090, which nginx does not serve.
keda:
  enabled: false

# During "DEPLOY SERVICE", src/PipelineArtifacts/ui-config/<ENV>/ is copied to the chart's files/
# folder and published as this ConfigMap.
configMap:
  volumeName: ui-config-volume
  filesPath: 'files/*'

mainContainer:
  volumeMounts:
    - name: ui-config-volume
      mountPath: /usr/share/nginx/html/assets/env/base-settings.json
      subPath: base-settings.json
  livenessProbe:
    enabled: true
    type: httpGet
    port: 4200
    path: /index.html
    initialDelaySeconds: 5
    periodSeconds: 20
    timeoutSeconds: 3
    failureThreshold: 3
  readinessProbe:
    enabled: true
    type: httpGet
    port: 4200
    path: /index.html
    initialDelaySeconds: 2
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 3

ingress:
  enabled: true
'@

Write-RepoFile $frontend 'src/jest.config.js' @'
// The SDT PR checker runs `npm run test:all -- --maxWorkers=2`, which Jest accepts directly.
const { createCjsPreset } = require('jest-preset-angular/presets');

/** @type {import('jest').Config} */
module.exports = {
  ...createCjsPreset(),
  setupFilesAfterEnv: ['<rootDir>/setup-jest.ts'],
  roots: ['<rootDir>/src'],
  collectCoverageFrom: ['src/app/**/*.ts', '!src/app/**/*.spec.ts'],
  coverageReporters: ['text-summary', 'cobertura', 'lcov'],
};
'@

Write-RepoFile $frontend 'src/package.json' @'
{
  "name": "tto-onboarding-portal-frontend",
  "version": "0.0.0",
  "scripts": {
    "ng": "ng",
    "start": "ng serve",
    "build": "ng build",
    "watch": "ng build --watch --configuration development",
    "lint": "eslint .",
    "lint:all": "eslint .",
    "test": "jest",
    "test:all": "jest --coverage"
  },
  "prettier": {
    "printWidth": 100,
    "singleQuote": true,
    "overrides": [
      {
        "files": "*.html",
        "options": {
          "parser": "angular"
        }
      }
    ]
  },
  "private": true,
  "dependencies": {
    "@angular/common": "^20.3.0",
    "@angular/compiler": "^20.3.0",
    "@angular/core": "^20.3.0",
    "@angular/forms": "^20.3.0",
    "@angular/platform-browser": "^20.3.0",
    "@angular/router": "^20.3.0",
    "rxjs": "~7.8.0",
    "tslib": "^2.3.0",
    "zone.js": "~0.15.0"
  },
  "devDependencies": {
    "@angular/build": "^20.3.39",
    "@angular/cli": "^20.3.39",
    "@angular/compiler-cli": "^20.3.0",
    "@eslint/js": "^9.39.0",
    "@types/jest": "^30.0.0",
    "angular-eslint": "^20.7.0",
    "eslint": "^9.39.0",
    "jest": "^30.5.2",
    "jest-environment-jsdom": "^30.5.2",
    "jest-preset-angular": "^17.0.3",
    "typescript": "~5.9.2",
    "typescript-eslint": "^8.71.2"
  }
}
'@

Write-RepoFile $frontend 'src/PipelineArtifacts/ui-config/DEV/base-settings.json' @'
{
  "appName": "tto-onboarding-portal",
  "environment": "dev",
  "apiBaseUrl": "https://aks-ingress.dev.ustax.deloitte.com/onboarding-portal-service"
}
'@

Write-RepoFile $frontend 'src/public/assets/env/base-settings.json' @'
{
  "appName": "tto-onboarding-portal",
  "environment": "local",
  "apiBaseUrl": "http://localhost:5000"
}
'@

Write-RepoFile $frontend 'src/setup-jest.ts' @'
import { setupZoneTestEnv } from 'jest-preset-angular/setup-env/zone';

setupZoneTestEnv();
'@

Write-RepoFile $frontend 'src/src/app/api/portal-api.service.spec.ts' @'
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';

import { RuntimeConfigService } from '../config/runtime-config.service';
import { ApiStatus, OnboardingRequest, PortalApiService } from './portal-api.service';

describe('PortalApiService', () => {
  const apiBaseUrl = 'http://api.test';
  let service: PortalApiService;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        {
          provide: RuntimeConfigService,
          useValue: { apiUrl: (path: string) => `${apiBaseUrl}${path}` },
        },
      ],
    });
    service = TestBed.inject(PortalApiService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  it('reports healthy when the readiness endpoint answers', () => {
    let status: ApiStatus | undefined;
    service.status().subscribe((value) => (status = value));

    http.expectOne(`${apiBaseUrl}/health/ready`).flush('Healthy');

    expect(status).toBe('healthy');
  });

  it('reports unavailable when the readiness endpoint fails', () => {
    let status: ApiStatus | undefined;
    service.status().subscribe((value) => (status = value));

    http
      .expectOne(`${apiBaseUrl}/health/ready`)
      .flush('Unhealthy', { status: 503, statusText: 'Service Unavailable' });

    expect(status).toBe('unavailable');
  });

  it('lists onboarding requests', () => {
    const requests: OnboardingRequest[] = [
      {
        id: '1',
        requestType: 'Asset',
        name: 'Tax Engine',
        description: null,
        status: 'Draft',
        currentStage: 'Intake',
        requestedBy: null,
        createdAt: '2026-10-14T10:00:00Z',
        updatedAt: '2026-10-14T10:00:00Z',
      },
    ];
    let result: OnboardingRequest[] | undefined;
    service.listRequests().subscribe((value) => (result = value));

    http.expectOne(`${apiBaseUrl}/api/onboarding-requests`).flush(requests);

    expect(result).toEqual(requests);
  });
});
'@

Write-RepoFile $frontend 'src/src/app/api/portal-api.service.ts' @'
import { HttpClient } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable, catchError, map, of } from 'rxjs';

import { RuntimeConfigService } from '../config/runtime-config.service';

export type OnboardingRequestType = 'Asset' | 'Service';

export interface OnboardingRequest {
  id: string;
  requestType: OnboardingRequestType;
  name: string;
  description: string | null;
  status: string;
  currentStage: string;
  requestedBy: string | null;
  createdAt: string;
  updatedAt: string;
}

export type ApiStatus = 'healthy' | 'unavailable';

@Injectable({ providedIn: 'root' })
export class PortalApiService {
  private readonly http = inject(HttpClient);
  private readonly config = inject(RuntimeConfigService);

  /** Readiness of the API, including its database connection. */
  status(): Observable<ApiStatus> {
    return this.http
      .get(this.config.apiUrl('/health/ready'), { responseType: 'text' })
      .pipe(
        map((): ApiStatus => 'healthy'),
        catchError(() => of<ApiStatus>('unavailable')),
      );
  }

  listRequests(): Observable<OnboardingRequest[]> {
    return this.http.get<OnboardingRequest[]>(this.config.apiUrl('/api/onboarding-requests'));
  }
}
'@

Write-RepoFile $frontend 'src/src/app/app.config.ts' @'
import { provideHttpClient, withFetch } from '@angular/common/http';
import {
  ApplicationConfig,
  inject,
  provideAppInitializer,
  provideBrowserGlobalErrorListeners,
  provideZoneChangeDetection,
} from '@angular/core';
import { provideRouter } from '@angular/router';

import { routes } from './app.routes';
import { RuntimeConfigService } from './config/runtime-config.service';

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideZoneChangeDetection({ eventCoalescing: true }),
    provideRouter(routes),
    provideHttpClient(withFetch()),
    provideAppInitializer(() => inject(RuntimeConfigService).load()),
  ],
};
'@

Write-RepoFile $frontend 'src/src/app/app.html' @'
<main class="portal">
  <header class="portal__header">
    <h1>TTO Onboarding Portal</h1>
    <p class="portal__subtitle">Asset and Service onboarding</p>
    <p class="portal__meta">
      Environment: <strong>{{ config.environment }}</strong>
      <span class="status" [class.status--ok]="apiStatus() === 'healthy'"
        [class.status--down]="apiStatus() === 'unavailable'" data-testid="api-status">
        API: {{ apiStatus() }}
      </span>
    </p>
  </header>

  <section class="portal__section" aria-labelledby="recent-requests">
    <h2 id="recent-requests">Recent onboarding requests</h2>

    @if (loadError()) {
      <p class="portal__error" role="alert">Onboarding requests could not be loaded.</p>
    } @else if (requests().length === 0) {
      <p data-testid="no-requests">No onboarding requests yet.</p>
    } @else {
      <table class="requests">
        <thead>
          <tr>
            <th scope="col">Name</th>
            <th scope="col">Type</th>
            <th scope="col">Status</th>
            <th scope="col">Stage</th>
            <th scope="col">Created</th>
          </tr>
        </thead>
        <tbody>
          @for (request of requests(); track request.id) {
            <tr>
              <td>{{ request.name }}</td>
              <td>{{ request.requestType }}</td>
              <td>{{ request.status }}</td>
              <td>{{ request.currentStage }}</td>
              <td>{{ request.createdAt | date: 'medium' }}</td>
            </tr>
          }
        </tbody>
      </table>
    }
  </section>
</main>
'@

Write-RepoFile $frontend 'src/src/app/app.routes.ts' @'
import { Routes } from '@angular/router';

export const routes: Routes = [];
'@

Write-RepoFile $frontend 'src/src/app/app.scss' @'
.portal {
  max-width: 960px;
  margin: 0 auto;
  padding: 2rem 1rem;
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  color: #1f2933;
}

.portal__header h1 {
  margin: 0;
  color: #0078d4;
}

.portal__subtitle {
  margin: 0.25rem 0 1rem;
  color: #52606d;
}

.portal__meta {
  display: flex;
  gap: 1rem;
  align-items: center;
}

.status {
  padding: 0.125rem 0.5rem;
  border-radius: 4px;
  background: #e4e7eb;
}

.status--ok {
  background: #e3f9e5;
  color: #05400a;
}

.status--down {
  background: #ffe3e3;
  color: #610404;
}

.portal__error {
  color: #610404;
}

.requests {
  width: 100%;
  border-collapse: collapse;
}

.requests th,
.requests td {
  padding: 0.5rem;
  border-bottom: 1px solid #e4e7eb;
  text-align: left;
}
'@

Write-RepoFile $frontend 'src/src/app/app.spec.ts' @'
import { TestBed } from '@angular/core/testing';
import { Observable, of, throwError } from 'rxjs';

import { ApiStatus, OnboardingRequest, PortalApiService } from './api/portal-api.service';
import { App } from './app';
import { RuntimeConfigService } from './config/runtime-config.service';

describe('App', () => {
  const request: OnboardingRequest = {
    id: '1',
    requestType: 'Service',
    name: 'Billing Service',
    description: null,
    status: 'Draft',
    currentStage: 'Intake',
    requestedBy: null,
    createdAt: '2026-10-14T10:00:00Z',
    updatedAt: '2026-10-14T10:00:00Z',
  };

  function render(status: ApiStatus, requests: Observable<OnboardingRequest[]>): HTMLElement {
    TestBed.configureTestingModule({
      imports: [App],
      providers: [
        {
          provide: RuntimeConfigService,
          useValue: { value: { appName: 'portal', environment: 'local', apiBaseUrl: '' } },
        },
        { provide: PortalApiService, useValue: { status: () => of(status), listRequests: () => requests } },
      ],
    });
    const fixture = TestBed.createComponent(App);
    fixture.detectChanges();
    return fixture.nativeElement as HTMLElement;
  }

  it('shows the environment and API status', () => {
    const page = render('healthy', of([]));

    expect(page.querySelector('h1')?.textContent).toContain('TTO Onboarding Portal');
    expect(page.textContent).toContain('Environment: local');
    expect(page.querySelector('[data-testid="api-status"]')?.textContent).toContain('API: healthy');
  });

  it('says when there are no requests', () => {
    const page = render('healthy', of([]));

    expect(page.querySelector('[data-testid="no-requests"]')).not.toBeNull();
  });

  it('lists onboarding requests', () => {
    const page = render('healthy', of([request]));

    const cells = Array.from(page.querySelectorAll('tbody td')).map((cell) => cell.textContent?.trim());
    expect(cells.slice(0, 4)).toEqual(['Billing Service', 'Service', 'Draft', 'Intake']);
  });

  it('shows an error when requests cannot be loaded', () => {
    const page = render('unavailable', throwError(() => new Error('offline')));

    expect(page.querySelector('[role="alert"]')?.textContent).toContain('could not be loaded');
    expect(page.querySelector('[data-testid="api-status"]')?.textContent).toContain('API: unavailable');
  });
});
'@

Write-RepoFile $frontend 'src/src/app/app.ts' @'
import { DatePipe } from '@angular/common';
import { Component, OnInit, inject, signal } from '@angular/core';

import { ApiStatus, OnboardingRequest, PortalApiService } from './api/portal-api.service';
import { RuntimeConfigService } from './config/runtime-config.service';

@Component({
  selector: 'app-root',
  imports: [DatePipe],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App implements OnInit {
  private readonly api = inject(PortalApiService);

  protected readonly config = inject(RuntimeConfigService).value;
  protected readonly apiStatus = signal<ApiStatus | 'checking'>('checking');
  protected readonly requests = signal<OnboardingRequest[]>([]);
  protected readonly loadError = signal(false);

  ngOnInit(): void {
    this.api.status().subscribe((status) => this.apiStatus.set(status));
    this.api.listRequests().subscribe({
      next: (requests) => this.requests.set(requests),
      error: () => this.loadError.set(true),
    });
  }
}
'@

Write-RepoFile $frontend 'src/src/app/config/runtime-config.service.spec.ts' @'
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';

import { RUNTIME_CONFIG_PATH, RuntimeConfigService } from './runtime-config.service';

describe('RuntimeConfigService', () => {
  let service: RuntimeConfigService;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      providers: [provideHttpClient(), provideHttpClientTesting()],
    });
    service = TestBed.inject(RuntimeConfigService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  async function loadWith(apiBaseUrl: string): Promise<void> {
    const loading = service.load();
    const request = http.expectOne(RUNTIME_CONFIG_PATH);
    expect(request.request.headers.get('Cache-Control')).toBe('no-cache');
    request.flush({ appName: 'portal', environment: 'test', apiBaseUrl });
    await loading;
  }

  it('throws when read before loading', () => {
    expect(() => service.value).toThrow('Runtime configuration has not been loaded.');
  });

  it('loads settings from the runtime config file', async () => {
    await loadWith('https://api.example.test');

    expect(service.value.environment).toBe('test');
  });

  it('joins the API base URL and path with exactly one slash', async () => {
    await loadWith('https://api.example.test/portal/');

    expect(service.apiUrl('/health')).toBe('https://api.example.test/portal/health');
    expect(service.apiUrl('api/onboarding-requests')).toBe(
      'https://api.example.test/portal/api/onboarding-requests',
    );
  });

  it('supports a same-origin API with an empty base URL', async () => {
    await loadWith('');

    expect(service.apiUrl('/health')).toBe('/health');
  });
});
'@

Write-RepoFile $frontend 'src/src/app/config/runtime-config.service.ts' @'
import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';

/**
 * Settings read at runtime from assets/env/base-settings.json.
 * Docker Compose uses the file baked into the image; each deployed environment replaces it
 * through the Helm ConfigMap built from src/PipelineArtifacts/ui-config/<ENV>/.
 */
export interface RuntimeConfig {
  appName: string;
  environment: string;
  apiBaseUrl: string;
}

export const RUNTIME_CONFIG_PATH = 'assets/env/base-settings.json';

@Injectable({ providedIn: 'root' })
export class RuntimeConfigService {
  private readonly http = inject(HttpClient);
  private config: RuntimeConfig | null = null;

  async load(): Promise<void> {
    // Bypass caches so a redeployed ConfigMap takes effect without a new image.
    const headers = new HttpHeaders({ 'Cache-Control': 'no-cache' });
    this.config = await firstValueFrom(this.http.get<RuntimeConfig>(RUNTIME_CONFIG_PATH, { headers }));
  }

  get value(): RuntimeConfig {
    if (!this.config) {
      throw new Error('Runtime configuration has not been loaded.');
    }
    return this.config;
  }

  apiUrl(path: string): string {
    const base = this.value.apiBaseUrl.replace(/\/+$/, '');
    const suffix = path.startsWith('/') ? path : `/${path}`;
    return `${base}${suffix}`;
  }
}
'@

Write-RepoFile $frontend 'src/src/index.html' @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>TTO Onboarding Portal</title>
  <base href="/">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" type="image/x-icon" href="favicon.ico">
</head>
<body>
  <app-root></app-root>
</body>
</html>
'@

Write-RepoFile $frontend 'src/src/main.ts' @'
import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { App } from './app/app';

bootstrapApplication(App, appConfig)
  .catch((err) => console.error(err));
'@

Write-RepoFile $frontend 'src/src/styles.scss' @'
/* You can add global styles to this file, and also import other style files */
'@

Write-RepoFile $frontend 'src/tsconfig.app.json' @'
/* To learn more about Typescript configuration file: https://www.typescriptlang.org/docs/handbook/tsconfig-json.html. */
/* To learn more about Angular compiler options: https://angular.dev/reference/configs/angular-compiler-options. */
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "outDir": "./out-tsc/app",
    "types": []
  },
  "include": [
    "src/**/*.ts"
  ],
  "exclude": [
    "src/**/*.spec.ts"
  ]
}
'@

Write-RepoFile $frontend 'src/tsconfig.json' @'
/* To learn more about Typescript configuration file: https://www.typescriptlang.org/docs/handbook/tsconfig-json.html. */
/* To learn more about Angular compiler options: https://angular.dev/reference/configs/angular-compiler-options. */
{
  "compileOnSave": false,
  "compilerOptions": {
    "strict": true,
    "noImplicitOverride": true,
    "noPropertyAccessFromIndexSignature": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "skipLibCheck": true,
    "isolatedModules": true,
    "experimentalDecorators": true,
    "importHelpers": true,
    "target": "ES2022",
    "module": "preserve"
  },
  "angularCompilerOptions": {
    "enableI18nLegacyMessageIdFormat": false,
    "strictInjectionParameters": true,
    "strictInputAccessModifiers": true,
    "typeCheckHostBindings": true,
    "strictTemplates": true
  },
  "files": [],
  "references": [
    {
      "path": "./tsconfig.app.json"
    },
    {
      "path": "./tsconfig.spec.json"
    }
  ]
}
'@

Write-RepoFile $frontend 'src/tsconfig.spec.json' @'
/* To learn more about Typescript configuration file: https://www.typescriptlang.org/docs/handbook/tsconfig-json.html. */
/* Jest runs the specs through jest-preset-angular as CommonJS. */
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "outDir": "./out-tsc/spec",
    "module": "CommonJS",
    "moduleResolution": "node10",
    "esModuleInterop": true,
    "types": [
      "jest"
    ]
  },
  "include": [
    "setup-jest.ts",
    "src/**/*.d.ts",
    "src/**/*.spec.ts"
  ]
}
'@

Remove-EmptyDirectories $frontend

Step "Generating src/package-lock.json (npm, inside a Node 22 container)"
Exec { docker run --rm -v "${frontendSrc}:/app" -w /app node:22-alpine npm install --package-lock-only --no-audit --no-fund }
Ok "frontend repository updated"

try {
    # -----------------------------------------------------------------------------------------------------
    # 6. Tests (same commands as the SDT PR checker)
    # -----------------------------------------------------------------------------------------------------
    if (-not $SkipTests) {
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        # Restore from nuget.org only: every package is public, and the repo nuget.config needs a CI token.
        [IO.File]::WriteAllText((Join-Path $tempDir "nuget.config"), '<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /><add key="nuget.org" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>', (New-Object Text.UTF8Encoding($false)))
        $testScript = "set -e`ncd /src`ndotnet restore Deloitte.TTO.OnboardingPortal.slnx --configfile /tools/nuget.config`ndotnet test --no-restore --configuration Test --collect:`"XPlat Code Coverage`" --results-directory /tmp/results`nfind /tmp/results -name coverage.cobertura.xml -exec grep -o 'line-rate=`"[0-9.]*`"' {} \; | head -1`n"
        [IO.File]::WriteAllText((Join-Path $tempDir "test.sh"), $testScript, (New-Object Text.UTF8Encoding($false)))

        Step "Backend tests (dotnet test -c Test with coverage, .NET 10 SDK container)"
        Exec { docker run --rm -v "${serviceFolder}:/src" -v "${tempDir}:/tools" -v "${nugetVolume}:/root/.nuget/packages" mcr.microsoft.com/dotnet/sdk:10.0 bash /tools/test.sh }
        Ok "backend tests passed"

        Step "Frontend lint and tests (npm run lint:all, npm run test:all -- --maxWorkers=2)"
        Exec { docker run --rm -v "${frontendSrc}:/app" -v "${nodeVolume}:/app/node_modules" -w /app node:22-alpine sh -c "npm ci --no-audit --no-fund && npm run lint:all && npm run test:all -- --maxWorkers=2" }
        Ok "frontend lint and tests passed"
    }

    # -----------------------------------------------------------------------------------------------------
    # 7. Build and start the stack, then verify end to end
    # -----------------------------------------------------------------------------------------------------
    Step "Building and starting the stack (first build takes several minutes)"
    Push-Location $service
    try { Exec { docker compose up -d --build } } finally { Pop-Location }

    Step "Verifying"
    $failed = 0
    foreach ($check in @(
            @{ Name = "API liveness"; Url = "http://localhost:5000/health" },
            @{ Name = "API readiness (database)"; Url = "http://localhost:5000/health/ready" },
            @{ Name = "Swagger"; Url = "http://localhost:5000/swagger/v1/swagger.json" },
            @{ Name = "Portal"; Url = "http://localhost:4200/" },
            @{ Name = "Portal runtime settings"; Url = "http://localhost:4200/assets/env/base-settings.json" })) {
        if (Wait-Http $check.Url) { Ok "$($check.Name)  $($check.Url)" } else { Fail "$($check.Name)  $($check.Url)"; $failed++ }
    }

    $created = $null
    try {
        $body = @{ requestType = "Asset"; name = "Tax Engine"; description = "Created by redo-onboarding-tasks.ps1" } | ConvertTo-Json
        $created = Invoke-RestMethod -Method Post -Uri "http://localhost:5000/api/onboarding-requests" -ContentType "application/json" -Body $body -TimeoutSec 15
        $fetched = Invoke-RestMethod -Uri "http://localhost:5000/api/onboarding-requests/$($created.id)" -TimeoutSec 15
        if ($fetched.id -eq $created.id) { Ok "Onboarding request saved and read back ($($created.id))" } else { Fail "Request read-back mismatch"; $failed++ }
    } catch { Fail "Create/read onboarding request: $($_.Exception.Message)"; $failed++ }

    if ($created) {
        Push-Location $service
        try { Exec { docker compose restart } } finally { Pop-Location }
        $persisted = $null
        $deadline = (Get-Date).AddSeconds(180)
        while (-not $persisted -and (Get-Date) -lt $deadline) {
            try { $persisted = Invoke-RestMethod -Uri "http://localhost:5000/api/onboarding-requests/$($created.id)" -TimeoutSec 5 } catch { Start-Sleep -Seconds 3 }
        }
        if ($persisted) { Ok "Request still present after restarting all containers" } else { Fail "Request missing after restart"; $failed++ }
    }

    Exec { docker ps --filter "name=onboarding" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" }
} finally {
    Step "Removing temporary files, build output and test volumes"
    Remove-Leftovers
    Ok "cleaned up"
}

if ($failed -gt 0) {
    Write-Host "`n$failed check(s) failed. Nothing was committed. Logs: cd `"$service`"; docker compose logs backend" -ForegroundColor Red
    exit 1
}

Step "Changes ready for review"
Write-Host "--- tto-onboarding-portal-service ---"; Exec { git -C $service status --short }
Write-Host "--- tto-onboarding-portal-frontend ---"; Exec { git -C $frontend status --short }

Write-Host "`n=== All checks passed ===" -ForegroundColor Green
Write-Host "  Portal  : http://localhost:4200"
Write-Host "  Swagger : http://localhost:5000/swagger"
Write-Host ""
Write-Host "Review, then commit, push and open a pull request into $BaseBranch in each repository:"
Write-Host "  cd `"$service`""
Write-Host "  git add -A; git commit -m `"AB#115139 AB#115140 backend data layer, migrations and DEV helm`"; git push -u origin $Branch"
Write-Host "  cd `"$frontend`""
Write-Host "  git add -A; git commit -m `"AB#115135 frontend runtime config, CI and helm`"; git push -u origin $Branch"
