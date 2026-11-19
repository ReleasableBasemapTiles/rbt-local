@{
    # PSScriptAnalyzer settings for the CI "Windows PowerShell 5.1" job.
    #
    # Error severity only. deploy.ps1 is long and its style is its own, so
    # warnings (Write-Host, unused variables, singular nouns and the like)
    # would be noise that people learn to ignore. The Error rules are the ones
    # that mark a script as wrong: a plaintext password parameter, a hard-coded
    # computer name, ConvertTo-SecureString on a plaintext string.
    #
    # Syntax errors are not this file's job. A script that doesn't parse is
    # reported by scripts/check.sh (PowerShell 7's parser) and by the job's
    # other step, which runs deploy.ps1 in Windows PowerShell 5.1 itself and so
    # also catches syntax that only 7 accepts.
    Severity = @('Error')
}
