-- =====================================================================================
-- Barker & Stonehouse: Search Console build (run with the query location set to EU)
--
-- The searchconsole dataset lives in the EU, so these marts are built and read there.
-- The dashboard queries this dataset directly, so no copy to europe-west2 is needed
-- (a copy is only needed if you later want to join Search Console to GA4 in SQL).
--
-- Schedule: daily at about 07:30 (query location EU).
-- =====================================================================================

DECLARE run_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP();
DECLARE today  DATE DEFAULT CURRENT_DATE('Europe/London');
DECLARE cur_end     DATE DEFAULT DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 3 DAY);
DECLARE cur_start   DATE DEFAULT DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 30 DAY);
DECLARE prior_end   DATE DEFAULT DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 31 DAY);
DECLARE prior_start DATE DEFAULT DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 58 DAY);

CREATE SCHEMA IF NOT EXISTS `commanding-air-450109-p0.gsc_marts` OPTIONS (location = 'EU');

CREATE TABLE IF NOT EXISTS `commanding-air-450109-p0.gsc_marts.build_log` (
  run_ts TIMESTAMP, step STRING, status STRING, message STRING, finished_at TIMESTAMP
);

CREATE OR REPLACE PROCEDURE `commanding-air-450109-p0.gsc_marts.log_step`(run_ts TIMESTAMP, step STRING, status STRING, message STRING)
BEGIN
  INSERT INTO `commanding-air-450109-p0.gsc_marts.build_log` (run_ts, step, status, message, finished_at)
  VALUES (run_ts, step, status, message, CURRENT_TIMESTAMP());
END;

CREATE OR REPLACE FUNCTION `commanding-air-450109-p0.gsc_marts.normalise_url`(url STRING)
RETURNS STRING AS (
  IF(url IS NULL, NULL,
     COALESCE(NULLIF(RTRIM(REGEXP_EXTRACT(LOWER(url), r'^(?:[a-z]+://[^/?#]+)?(/[^?#]*)'), '/'), ''), '/'))
);

CREATE TABLE IF NOT EXISTS `commanding-air-450109-p0.gsc_marts.seo_alerts` (
  rule_code STRING, entity_type STRING, entity_id STRING, entity_name STRING,
  metric_value FLOAT64, baseline_value FLOAT64, est_gbp_week FLOAT64, est_clicks_week FLOAT64,
  confidence STRING, owner_pillar STRING, priority STRING, recommended_action STRING, evidence STRING,
  first_seen DATE, last_seen DATE, run_count INT64
);

-- ---------- 1. query x page opportunities (28 days) ----------
-- sum_position is zero-based, so add 1 for the rank shown in Search Console.
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.gsc_marts.query_page_opportunities` AS
  WITH base AS (
    SELECT
      query,
      `commanding-air-450109-p0.gsc_marts.normalise_url`(url) AS page,
      REGEXP_CONTAINS(query, r'barker|stone ?house|\bb ?(&|and) ?s\b') AS is_brand,
      SUM(impressions) AS impressions,
      SUM(clicks)      AS clicks,
      SAFE_DIVIDE(SUM(sum_position), SUM(impressions)) + 1 AS avg_position
    FROM `commanding-air-450109-p0.searchconsole.searchdata_url_impression`
    WHERE data_date BETWEEN cur_start AND cur_end
      AND search_type = 'WEB'
      AND NOT is_anonymized_query
    GROUP BY query, page, is_brand
  ),
  curve AS (
    SELECT
      LEAST(CAST(ROUND(avg_position) AS INT64), 20) AS pos,
      SAFE_DIVIDE(SUM(clicks), SUM(impressions)) AS expected_ctr
    FROM base
    WHERE NOT is_brand
    GROUP BY pos
  )
  SELECT * FROM (
    SELECT
      b.query, b.page, b.impressions, b.clicks,
      ROUND(b.avg_position, 1)             AS avg_position,
      SAFE_DIVIDE(b.clicks, b.impressions) AS ctr,
      c.expected_ctr,
      GREATEST(0, b.impressions * c.expected_ctr - b.clicks)         AS ctr_gap_clicks,
      GREATEST(0, b.impressions * (t.expected_ctr - c.expected_ctr)) AS rank_gap_clicks,
      CASE
        WHEN b.avg_position <= 5 AND b.impressions >= 1000
         AND SAFE_DIVIDE(b.clicks, b.impressions) < 0.6 * c.expected_ctr THEN 'Rewrite title and meta'
        WHEN b.avg_position BETWEEN 4 AND 15 AND b.impressions >= 500   THEN 'Striking distance'
      END AS opportunity
    FROM base AS b
    JOIN curve AS c ON c.pos = LEAST(CAST(ROUND(b.avg_position) AS INT64), 20)
    LEFT JOIN (SELECT expected_ctr FROM curve WHERE pos = 3) AS t ON TRUE
    WHERE NOT b.is_brand
  )
  WHERE opportunity IS NOT NULL;

  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'query_page_opportunities', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'query_page_opportunities', 'error', @@error.message);
END;

-- ---------- 2. page trend: last 28 days against the 28 before ----------
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.gsc_marts.page_trend` AS
  WITH w AS (
    SELECT
      `commanding-air-450109-p0.gsc_marts.normalise_url`(url) AS page,
      IF(data_date >= cur_start, 'cur', 'prior') AS period,
      clicks, impressions, sum_position
    FROM `commanding-air-450109-p0.searchconsole.searchdata_url_impression`
    WHERE data_date BETWEEN prior_start AND cur_end
      AND search_type = 'WEB'
      AND NOT COALESCE(REGEXP_CONTAINS(query, r'barker|stone ?house|\bb ?(&|and) ?s\b'), FALSE)
  ),
  p AS (
    SELECT
      page,
      SUM(IF(period = 'cur', clicks, 0))         AS clicks_cur,
      SUM(IF(period = 'prior', clicks, 0))       AS clicks_prior,
      SUM(IF(period = 'cur', impressions, 0))    AS impressions_cur,
      SUM(IF(period = 'prior', impressions, 0))  AS impressions_prior,
      SAFE_DIVIDE(SUM(IF(period = 'cur', sum_position, 0)),   SUM(IF(period = 'cur', impressions, 0))) + 1   AS pos_cur,
      SAFE_DIVIDE(SUM(IF(period = 'prior', sum_position, 0)), SUM(IF(period = 'prior', impressions, 0))) + 1 AS pos_prior
    FROM w
    GROUP BY page
  )
  SELECT
    p.*,
    SAFE_DIVIDE(clicks_cur - clicks_prior, clicks_prior) AS change_pct,
    SAFE_DIVIDE(SUM(clicks_cur) OVER () - SUM(clicks_prior) OVER (), SUM(clicks_prior) OVER ()) AS site_change_pct
  FROM p;

  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'page_trend', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'page_trend', 'error', @@error.message);
END;

-- ---------- 3. daily visibility: brand, non-brand and anonymised queries ----------
BEGIN
  CREATE OR REPLACE TABLE `commanding-air-450109-p0.gsc_marts.visibility_daily` AS
  SELECT
    data_date,
    CASE
      WHEN is_anonymized_query THEN 'Anonymised'
      WHEN REGEXP_CONTAINS(query, r'barker|stone ?house|\bb ?(&|and) ?s\b') THEN 'Brand'
      ELSE 'Non-brand'
    END AS segment,
    SUM(clicks) AS clicks,
    SUM(impressions) AS impressions,
    SAFE_DIVIDE(SUM(sum_position), SUM(impressions)) + 1 AS avg_position
  FROM `commanding-air-450109-p0.searchconsole.searchdata_url_impression`
  WHERE data_date >= DATE_SUB(CURRENT_DATE('Europe/London'), INTERVAL 120 DAY)
    AND search_type = 'WEB'
  GROUP BY data_date, segment;

  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'visibility_daily', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'visibility_daily', 'error', @@error.message);
END;

-- ---------- 4. SEO alerts ----------
CREATE TEMP TABLE seo_today (
  rule_code STRING, entity_type STRING, entity_id STRING, entity_name STRING,
  metric_value FLOAT64, baseline_value FLOAT64, est_gbp_week FLOAT64, est_clicks_week FLOAT64,
  confidence STRING, owner_pillar STRING, priority STRING, recommended_action STRING, evidence STRING
);

-- Rewrite titles and meta: high on the page, low click-through for that position
BEGIN
  INSERT INTO seo_today
  SELECT 'SEO_CTR', 'page', page, page,
         SAFE_DIVIDE(SUM(clicks), SUM(impressions)), SAFE_DIVIDE(SUM(impressions * expected_ctr), SUM(impressions)),
         NULL, SUM(ctr_gap_clicks) / 4, IF(SUM(impressions) >= 5000, 'high', 'medium'), 'SEO/Content', 'P2',
         'Rewrite the title and meta description around the main query; check for a new AI Overview or Shopping unit above the result.',
         FORMAT('Top query "%s": position %.1f, %d impressions, %.1f%% click-through against %.1f%% expected',
                ARRAY_AGG(query ORDER BY ctr_gap_clicks DESC LIMIT 1)[OFFSET(0)],
                ARRAY_AGG(avg_position ORDER BY ctr_gap_clicks DESC LIMIT 1)[OFFSET(0)],
                ARRAY_AGG(impressions ORDER BY ctr_gap_clicks DESC LIMIT 1)[OFFSET(0)],
                100 * ARRAY_AGG(ctr ORDER BY ctr_gap_clicks DESC LIMIT 1)[OFFSET(0)],
                100 * ARRAY_AGG(expected_ctr ORDER BY ctr_gap_clicks DESC LIMIT 1)[OFFSET(0)])
  FROM `commanding-air-450109-p0.gsc_marts.query_page_opportunities`
  WHERE opportunity = 'Rewrite title and meta'
  GROUP BY page;
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'alert_seo_ctr', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'alert_seo_ctr', 'error', @@error.message);
END;

-- Organic visibility drop: clicks well down, clearly worse than the site, and ranking lower
BEGIN
  INSERT INTO seo_today
  SELECT 'SEO_DROP', 'page', page, page, clicks_cur, clicks_prior, NULL, (clicks_prior - clicks_cur) / 4,
         IF(clicks_prior >= 300, 'high', 'medium'), 'SEO/Content', 'P2',
         'Check indexation, canonicals, redirects and recent template or content changes; 301 the page if the product has left the feed.',
         FORMAT('Clicks %d against %d in the previous 28 days (%.0f%%); average position %.1f against %.1f',
                clicks_cur, clicks_prior, 100 * change_pct, pos_cur, pos_prior)
  FROM `commanding-air-450109-p0.gsc_marts.page_trend`
  WHERE clicks_prior >= 100 AND change_pct <= -0.30 AND change_pct - site_change_pct <= -0.20
    AND pos_cur - pos_prior >= 3;
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'alert_seo_drop', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'alert_seo_drop', 'error', @@error.message);
END;

BEGIN
  MERGE `commanding-air-450109-p0.gsc_marts.seo_alerts` AS t
  USING (
    SELECT * FROM seo_today
    QUALIFY ROW_NUMBER() OVER (PARTITION BY rule_code, entity_id ORDER BY est_clicks_week DESC) = 1
  ) AS s
  ON t.rule_code = s.rule_code AND t.entity_id = s.entity_id
  WHEN MATCHED THEN UPDATE SET
    entity_name = s.entity_name, metric_value = s.metric_value, baseline_value = s.baseline_value,
    est_gbp_week = s.est_gbp_week, est_clicks_week = s.est_clicks_week, confidence = s.confidence,
    owner_pillar = s.owner_pillar, priority = s.priority, recommended_action = s.recommended_action,
    evidence = s.evidence,
    first_seen = IF(t.last_seen >= DATE_SUB(today, INTERVAL 7 DAY), t.first_seen, today),
    run_count  = IF(t.last_seen = today, t.run_count, IF(t.last_seen >= DATE_SUB(today, INTERVAL 7 DAY), t.run_count + 1, 1)),
    last_seen  = today
  WHEN NOT MATCHED THEN INSERT
    (rule_code, entity_type, entity_id, entity_name, metric_value, baseline_value, est_gbp_week, est_clicks_week,
     confidence, owner_pillar, priority, recommended_action, evidence, first_seen, last_seen, run_count)
  VALUES
    (s.rule_code, s.entity_type, s.entity_id, s.entity_name, s.metric_value, s.baseline_value, s.est_gbp_week, s.est_clicks_week,
     s.confidence, s.owner_pillar, s.priority, s.recommended_action, s.evidence, today, today, 1);
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'seo_alerts_merge', 'ok', NULL);
EXCEPTION WHEN ERROR THEN
  CALL `commanding-air-450109-p0.gsc_marts.log_step`(run_ts, 'seo_alerts_merge', 'error', @@error.message);
END;
