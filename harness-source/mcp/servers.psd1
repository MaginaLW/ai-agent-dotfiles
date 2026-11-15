@{
    # Managed MCP server registry projected per declared entry to Antigravity, Codex, and ZCode.
    # Keep zero plaintext secrets, tokens, or machine-private paths here.
    SchemaVersion = 1
    Servers = @(
        @{
            Name = 'blender'
            Transport = 'stdio'
            Command = 'uvx'
            Args = @('mcp-for-blender')
            Env = @{}
            Enabled = $true
            Platforms = @('Antigravity', 'Codex', 'ZCode')
        }
    )
}
