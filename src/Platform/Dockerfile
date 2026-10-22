FROM mcr.microsoft.com/dotnet/sdk:10.0.402@sha256:747cbade5bfd918a175ac32f8f1d931edec2c7d0d5397a3de72eaef1ac1f66d2 AS build
WORKDIR /source
COPY Directory.Build.props global.json ./
COPY src/Platform/Platform.csproj src/Platform/packages.lock.json src/Platform/
RUN dotnet restore src/Platform/Platform.csproj --locked-mode
COPY src/Platform/ src/Platform/
RUN dotnet publish src/Platform/Platform.csproj -c Release -o /app --no-restore
FROM mcr.microsoft.com/dotnet/runtime:10.0@sha256:0cf09aaccf6a9f68900aed4c73fb28fe25bb59ec85de4dea08ba02240a8635f3
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
ENTRYPOINT ["dotnet", "platform.dll"]
