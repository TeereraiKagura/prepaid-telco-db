-- =============================================================================
-- Seed 01  Reference data for "Zambezi Mobile", a fictional Zimbabwean operator
-- =============================================================================
-- Idempotent: safe to run more than once.

INSERT INTO telco.regions (region_code, name, country_code, is_urban) VALUES
    ('HRE', 'Harare',               'ZW', true),
    ('BYO', 'Bulawayo',             'ZW', true),
    ('MCE', 'Manicaland',           'ZW', false),
    ('MSC', 'Mashonaland Central',  'ZW', false),
    ('MSE', 'Mashonaland East',     'ZW', false),
    ('MSW', 'Mashonaland West',     'ZW', false),
    ('MVG', 'Masvingo',             'ZW', false),
    ('MBN', 'Matabeleland North',   'ZW', false),
    ('MBS', 'Matabeleland South',   'ZW', false),
    ('MID', 'Midlands',             'ZW', false)
ON CONFLICT (region_code) DO NOTHING;

INSERT INTO telco.sales_channels (channel_code, name, is_digital, supports_topups, supports_bundles) VALUES
    ('USSD',         'USSD self-service menu',          true,  false, true),
    ('APP',          'Self-care mobile app',            true,  true,  true),
    ('MOBILE_MONEY', 'Mobile money wallet',             true,  true,  true),
    ('BANK',         'Bank app / internet banking',     true,  true,  false),
    ('RETAIL',       'Retail agent electronic recharge', false, true,  false),
    ('VOUCHER',      'Scratch card voucher',            false, true,  false)
ON CONFLICT (channel_code) DO NOTHING;

INSERT INTO telco.payg_rates (usage_type, rate_per_unit, unit_label) VALUES
    ('data',  0.020000, 'per MB'),
    ('voice', 0.001500, 'per second'),
    ('sms',   0.030000, 'per SMS')
ON CONFLICT (usage_type) DO NOTHING;

INSERT INTO telco.bundles (bundle_code, name, category, validity, launched_on) VALUES
    ('DATA_DAILY_100MB',    'Daily 100MB',                 'data',   '1 day',    '2024-01-01'),
    ('DATA_DAILY_500MB',    'Daily 500MB',                 'data',   '1 day',    '2024-01-01'),
    ('DATA_WEEKLY_1GB',     'Weekly 1GB',                  'data',   '7 days',   '2024-01-01'),
    ('DATA_WEEKLY_3GB',     'Weekly 3GB',                  'data',   '7 days',   '2024-01-01'),
    ('DATA_MONTHLY_5GB',    'Monthly 5GB',                 'data',   '30 days',  '2024-01-01'),
    ('DATA_MONTHLY_20GB',   'Monthly 20GB',                'data',   '30 days',  '2024-01-01'),
    ('NIGHT_DATA_2GB',      'Night Owl 2GB (00:00-06:00)', 'data',   '12 hours', '2026-03-01'),
    ('SOCIAL_DAILY_WA',     'WhatsApp Daily',              'social', '1 day',    '2024-01-01'),
    ('SOCIAL_WEEKLY',       'Social Weekly',               'social', '7 days',   '2024-01-01'),
    ('VOICE_DAILY_20MIN',   'Talk Daily 20 min',           'voice',  '1 day',    '2024-01-01'),
    ('VOICE_WEEKLY_100MIN', 'Talk Weekly 100 min',         'voice',  '7 days',   '2024-01-01'),
    ('SMS_DAILY_100',       'SMS Daily 100',               'sms',    '1 day',    '2024-01-01'),
    ('SMS_WEEKLY_500',      'SMS Weekly 500',              'sms',    '7 days',   '2024-01-01'),
    ('COMBO_WEEKLY',        'Smart Weekly Combo',          'combo',  '7 days',   '2024-01-01'),
    ('COMBO_MONTHLY',       'Smart Monthly Combo',         'combo',  '30 days',  '2024-01-01')
ON CONFLICT (bundle_code) DO NOTHING;

INSERT INTO telco.bundle_allowances (bundle_id, unit, quantity)
SELECT b.bundle_id, a.unit::telco.allowance_unit, a.quantity
FROM (VALUES
    ('DATA_DAILY_100MB',    'data_mb',         100),
    ('DATA_DAILY_500MB',    'data_mb',         500),
    ('DATA_WEEKLY_1GB',     'data_mb',        1024),
    ('DATA_WEEKLY_3GB',     'data_mb',        3072),
    ('DATA_MONTHLY_5GB',    'data_mb',        5120),
    ('DATA_MONTHLY_20GB',   'data_mb',       20480),
    ('NIGHT_DATA_2GB',      'data_mb',        2048),
    ('SOCIAL_DAILY_WA',     'data_mb',          50),
    ('SOCIAL_WEEKLY',       'data_mb',         250),
    ('VOICE_DAILY_20MIN',   'voice_seconds',  1200),
    ('VOICE_WEEKLY_100MIN', 'voice_seconds',  6000),
    ('SMS_DAILY_100',       'sms',             100),
    ('SMS_WEEKLY_500',      'sms',             500),
    ('COMBO_WEEKLY',        'data_mb',        1024),
    ('COMBO_WEEKLY',        'voice_seconds',  3000),
    ('COMBO_WEEKLY',        'sms',             100),
    ('COMBO_MONTHLY',       'data_mb',        5120),
    ('COMBO_MONTHLY',       'voice_seconds', 18000),
    ('COMBO_MONTHLY',       'sms',             500)
) AS a (bundle_code, unit, quantity)
JOIN telco.bundles b USING (bundle_code)
ON CONFLICT (bundle_id, unit) DO NOTHING;

-- Price history, including two price changes during the dataset:
--   DATA_WEEKLY_1GB  3.00 -> 3.50 on 2026-04-01 (increase)
--   DATA_MONTHLY_5GB 10.00 -> 9.00 on 2026-02-01 (cut)
INSERT INTO telco.bundle_prices (bundle_id, price, valid_during)
SELECT b.bundle_id, p.price, tstzrange(p.valid_from, p.valid_to, '[)')
FROM (VALUES
    ('DATA_DAILY_100MB',     0.50, timestamptz '2025-01-01 00:00+02', NULL::timestamptz),
    ('DATA_DAILY_500MB',     1.00, '2025-01-01 00:00+02', NULL),
    ('DATA_WEEKLY_1GB',      3.00, '2025-01-01 00:00+02', '2026-04-01 00:00+02'),
    ('DATA_WEEKLY_1GB',      3.50, '2026-04-01 00:00+02', NULL),
    ('DATA_WEEKLY_3GB',      6.00, '2025-01-01 00:00+02', NULL),
    ('DATA_MONTHLY_5GB',    10.00, '2025-01-01 00:00+02', '2026-02-01 00:00+02'),
    ('DATA_MONTHLY_5GB',     9.00, '2026-02-01 00:00+02', NULL),
    ('DATA_MONTHLY_20GB',   25.00, '2025-01-01 00:00+02', NULL),
    ('NIGHT_DATA_2GB',       1.00, '2026-03-01 00:00+02', NULL),
    ('SOCIAL_DAILY_WA',      0.30, '2025-01-01 00:00+02', NULL),
    ('SOCIAL_WEEKLY',        1.50, '2025-01-01 00:00+02', NULL),
    ('VOICE_DAILY_20MIN',    0.75, '2025-01-01 00:00+02', NULL),
    ('VOICE_WEEKLY_100MIN',  3.00, '2025-01-01 00:00+02', NULL),
    ('SMS_DAILY_100',        0.20, '2025-01-01 00:00+02', NULL),
    ('SMS_WEEKLY_500',       0.80, '2025-01-01 00:00+02', NULL),
    ('COMBO_WEEKLY',         4.00, '2025-01-01 00:00+02', NULL),
    ('COMBO_MONTHLY',       15.00, '2025-01-01 00:00+02', NULL)
) AS p (bundle_code, price, valid_from, valid_to)
JOIN telco.bundles b USING (bundle_code)
WHERE NOT EXISTS (SELECT 1 FROM telco.bundle_prices x WHERE x.bundle_id = b.bundle_id);
