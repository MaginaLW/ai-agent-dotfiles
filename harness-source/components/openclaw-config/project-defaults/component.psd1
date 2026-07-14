@{
    SchemaVersion = 1
    Id = 'openclaw-project-defaults'
    Kind = 'OpenClawConfig'
    TargetPlatforms = @('OpenClaw')
    Requires = @()
    Conflicts = @()
    Outputs = @(
        @{
            Target = '.openclaw/project.json'
            Mode = 'StructuredMerge'
            MergeStrategy = 'JsonObject'
        }
    )
}
