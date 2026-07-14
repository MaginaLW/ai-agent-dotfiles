@{
    SchemaVersion = 1
    Id = 'github'
    Description = 'GitHub MCP server using a process environment token placeholder.'
    Command = 'npx'
    Args = @('-y', '@modelcontextprotocol/server-github')
    RequiredEnv = @('GITHUB_PERSONAL_ACCESS_TOKEN')
    Env = @{
        GITHUB_PERSONAL_ACCESS_TOKEN = '${GITHUB_PERSONAL_ACCESS_TOKEN}'
    }
    Scope = 'user'
}
