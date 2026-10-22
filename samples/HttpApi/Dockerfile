FROM mcr.microsoft.com/dotnet/sdk:10.0.402@sha256:747cbade5bfd918a175ac32f8f1d931edec2c7d0d5397a3de72eaef1ac1f66d2 AS build
WORKDIR /source
COPY Directory.Build.props global.json ./
COPY samples/HttpApi/HttpApi.csproj samples/HttpApi/packages.lock.json samples/HttpApi/
RUN dotnet restore samples/HttpApi/HttpApi.csproj --locked-mode
COPY samples/HttpApi/ samples/HttpApi/
RUN dotnet publish samples/HttpApi/HttpApi.csproj -c Release -o /app --no-restore
FROM mcr.microsoft.com/dotnet/aspnet:10.0@sha256:8af87eba5e7cdafb1514d7388be287365da97c132509e84dfe252ffd552398ca
WORKDIR /app
COPY --from=build /app .
USER $APP_UID
ENTRYPOINT ["dotnet", "HttpApi.dll"]
