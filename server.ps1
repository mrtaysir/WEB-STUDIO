param(
  [int]$Port = 5500
)

function Load-DotEnv {
  $envPath = Join-Path (Get-Location) ".env"
  $vars = @{}
  if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
      $line = $_.Trim()
      if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $kv = $line.Split("=",2)
        $key = $kv[0].Trim()
        $val = $kv[1].Trim()
        $vars[$key] = $val
      }
    }
  }
  return $vars
}

$cfg = Load-DotEnv

$SMTP_HOST = $cfg['SMTP_HOST']
$SMTP_PORT = if ($cfg.ContainsKey('SMTP_PORT')) { [int]$cfg['SMTP_PORT'] } else { 587 }
$SMTP_USERNAME = $cfg['SMTP_USERNAME']
$SMTP_PASSWORD = $cfg['SMTP_PASSWORD']
$MAIL_TO = $cfg['MAIL_TO']
$MAIL_FROM = $cfg['MAIL_FROM']

Write-Host "SMTP HOST=$SMTP_HOST PORT=$SMTP_PORT TO=$MAIL_TO FROM=$MAIL_FROM"

$root = (Get-Location).Path
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $root at http://localhost:$Port/"

while ($true) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request
  $res = $ctx.Response
  $path = $req.Url.AbsolutePath

  if ($req.HttpMethod -eq 'POST' -and $path -eq '/send') {
    try {
      $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
      $raw = $reader.ReadToEnd()
      $pairs = $raw -split '&'
      $form = @{}
      foreach ($p in $pairs) {
        if (-not [string]::IsNullOrWhiteSpace($p)) {
          $kv = $p -split '=',2
          $k = [System.Net.WebUtility]::UrlDecode($kv[0])
          $v = if ($kv.Count -gt 1) { [System.Net.WebUtility]::UrlDecode($kv[1]) } else { '' }
          $form[$k] = $v
        }
      }

      $name = $form['name']
      $email = $form['email']
      $message = $form['message']

      if (-not $SMTP_HOST -or -not $SMTP_USERNAME -or -not $SMTP_PASSWORD -or -not $MAIL_TO -or -not $MAIL_FROM) {
        throw "SMTP configuration missing. Please create .env with SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, MAIL_TO, MAIL_FROM"
      }

      $mail = New-Object System.Net.Mail.MailMessage
      $mail.From = New-Object System.Net.Mail.MailAddress($MAIL_FROM)
      $mail.To.Add($MAIL_TO)
      $mail.Subject = "New message from WEB STUDIO: $name"
      $mail.Body = "Name: $name`nEmail: $email`n`nMessage:`n$message"
      $mail.IsBodyHtml = $false

      $client = New-Object System.Net.Mail.SmtpClient($SMTP_HOST, $SMTP_PORT)
      $client.EnableSsl = $true
      $client.Credentials = New-Object System.Net.NetworkCredential($SMTP_USERNAME, $SMTP_PASSWORD)
      $client.Send($mail)

      $json = '{"ok":true,"message":"تم الإرسال بنجاح"}'
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $res.ContentType = 'application/json'
      $res.StatusCode = 200
      $res.OutputStream.Write($bytes,0,$bytes.Length)
    } catch {
      $err = $_.Exception.Message
      $json = '{"ok":false,"error":"' + ($err -replace '"','\"') + '"}'
      $bytes = [Text.Encoding]::UTF8.GetBytes($json)
      $res.ContentType = 'application/json'
      $res.StatusCode = 500
      $res.OutputStream.Write($bytes,0,$bytes.Length)
    }
    $res.OutputStream.Close()
    continue
  }

  # Static files
  $relative = $req.Url.AbsolutePath.TrimStart('/')
  if ([string]::IsNullOrEmpty($relative)) { $relative = 'index.html' }
  $filePath = Join-Path $root $relative
  if (Test-Path $filePath) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
    switch ($ext) {
      '.html' { $res.ContentType = 'text/html' }
      '.css'  { $res.ContentType = 'text/css' }
      '.svg'  { $res.ContentType = 'image/svg+xml' }
      '.png'  { $res.ContentType = 'image/png' }
      '.jpg'  { $res.ContentType = 'image/jpeg' }
      '.jpeg' { $res.ContentType = 'image/jpeg' }
      default { $res.ContentType = 'application/octet-stream' }
    }
    $res.OutputStream.Write($bytes,0,$bytes.Length)
  } else {
    $res.StatusCode = 404
    $msg = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
    $res.OutputStream.Write($msg,0,$msg.Length)
  }
  $res.OutputStream.Close()
}
