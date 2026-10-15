/*
  Q06  When do customers buy bundles (local time)?
  ----------------------------------------------------------------------------
  Bundle purchases by local hour x weekday over the last 90 days, plus a text
  histogram. Used to time promotions/SMS campaigns and to size the charging
  platform for the evening peak. Timestamps are stored as timestamptz and
  converted to the operator's time zone only for reporting.

  Techniques: time-zone conversion, EXTRACT(isodow), window over an aggregate
*/
WITH purchases AS (
    SELECT analytics.local_ts(purchased_at) AS local_time
    FROM telco.bundle_purchases
    WHERE purchased_at >= analytics.as_of() - interval '90 days'
      AND purchased_at <  analytics.as_of()
)
SELECT extract(hour FROM local_time)::int                         AS hour,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 1) AS mon,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 2) AS tue,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 3) AS wed,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 4) AS thu,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 5) AS fri,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 6) AS sat,
       count(*) FILTER (WHERE extract(isodow FROM local_time) = 7) AS sun,
       count(*)                                                    AS total,
       repeat('#', (40 * count(*) / max(count(*)) OVER ())::int)   AS histogram
FROM purchases
GROUP BY 1
ORDER BY 1;
