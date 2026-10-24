-- PID-286 migration data. Keep immutable: seeds and the migration use the same defaults.
INSERT INTO email_templates
  (id, kind, key, name, subject, html_body, variables, inserted_at, updated_at)
VALUES
  (gen_random_uuid(), 'transactional', 'password_reset', 'Password reset',
   'Reset your Pidro password',
   '<p style="margin:0 0 24px;">Reset your Pidro password:</p>
<p style="margin:0 0 24px;"><a class="email-button" href="{{reset_url}}" style="display:inline-block;padding:16px 20px;background-color:#e1ad3a;color:#1e0e04;border:1px solid #a86b17;border-radius:8px;font-weight:bold;text-decoration:none;font-size:20px;line-height:1.4;">Choose a new password</a></p>
<p style="margin:0 0 24px;font-size:16px;overflow-wrap:anywhere;word-break:break-all;"><a href="{{reset_url}}" style="color:#0d5087;">{{reset_url}}</a></p>
<p style="margin:0;">This link expires in 1 hour.</p>',
   ARRAY['{{username}}', '{{reset_url}}'], now(), now()),
  (gen_random_uuid(), 'transactional', 'classic_sign_in_code', 'Classic sign-in code',
   'Your Pidro sign-in code',
   '<p style="margin:0 0 24px;text-align:center;font-size:44px;font-weight:bold;letter-spacing:6px;line-height:1.4;">{{code}}</p>
<p style="margin:0 0 24px;">It works for 15 minutes</p>
<p style="margin:0;">If you did not ask for this, ignore this mail</p>',
   ARRAY['{{code}}'], now(), now()),
  (gen_random_uuid(), 'transactional', 'classic_help', 'Classic account help',
   'Help finding a Classic account: {{name}}',
   '<p style="margin:0 0 16px;">Name: {{name}}</p>
<p style="margin:0 0 16px;">Email: {{email}}</p>
<p style="margin:0 0 16px;white-space:pre-wrap;">Details: {{details}}</p>
<p style="margin:0;">{{user_line}}</p>',
   ARRAY['{{name}}', '{{email}}', '{{details}}', '{{user_line}}'], now(), now())
ON CONFLICT (kind, key) DO NOTHING;
