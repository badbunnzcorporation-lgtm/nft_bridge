/**
 * Check DB connection and that the stats/recent query works.
 * Run from backend/: npm run db:check
 * Requires DATABASE_URL in .env.
 */
import 'dotenv/config';
import pg from 'pg';

const { Pool } = pg;

const pool = new Pool({ connectionString: process.env.DATABASE_URL });

const statsRecentQuery = `
  SELECT 
    le.token_id,
    le.chain,
    le.status,
    le.created_at,
    le.updated_at,
    ue.tx_hash as unlock_tx_hash,
    EXTRACT(EPOCH FROM (le.updated_at - le.created_at)) as duration_seconds
  FROM lock_events le
  LEFT JOIN unlock_events ue ON le.lock_hash = ue.lock_hash
  ORDER BY le.created_at DESC
  LIMIT 5
`;

async function main() {
  try {
    await pool.query('SELECT 1');
    console.log('DB connection: OK');
    const result = await pool.query(statsRecentQuery);
    console.log('Stats/recent query: OK, rows:', result.rows.length);
    process.exit(0);
  } catch (err) {
    console.error('DB check failed:', err.message);
    if (err.code) console.error('Code:', err.code);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

main();
