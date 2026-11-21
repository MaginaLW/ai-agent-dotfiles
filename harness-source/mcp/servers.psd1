@{
    # Managed MCP server registry projected per declared entry to Antigravity and Codex.
    # Keep zero plaintext secrets, tokens, or machine-private paths here.
    SchemaVersion = 1
    Servers = @(
        @{
            Name = 'blender'
            Transport = 'stdio'
            Command = 'uvx'
            Args = @('mcp-for-blender')
            Env = @{ BLENDER_PORT = '9800' }
            Enabled = $true
            Platforms = @('Antigravity', 'Codex')
        }
    )
}
