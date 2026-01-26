-- Database schema for Bad Bunnz Bridge Backend

-- Lock events from both chains
CREATE TABLE IF NOT EXISTS lock_events (
  id SERIAL PRIMARY KEY,
  token_id INTEGER NOT NULL,
  owner_address VARCHAR(42) NOT NULL,
  recipient_address VARCHAR(42) NOT NULL,
  lock_hash VARCHAR(66) NOT NULL UNIQUE,
  block_number INTEGER NOT NULL,
  block_timestamp TIMESTAMP NOT NULL,
  chain VARCHAR(20) NOT NULL CHECK (chain IN ('ethereum', 'megaeth')),
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'proof_generated', 'root_submitted', 'unlocked', 'failed')),
  tx_hash VARCHAR(66) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lock_hash ON lock_events(lock_hash);
CREATE INDEX IF NOT EXISTS idx_token_id ON lock_events(token_id);
CREATE INDEX IF NOT EXISTS idx_block_number ON lock_events(block_number, chain);
CREATE INDEX IF NOT EXISTS idx_status ON lock_events(status);
CREATE INDEX IF NOT EXISTS idx_recipient ON lock_events(recipient_address);

-- Merkle proofs for unlocking
CREATE TABLE IF NOT EXISTS merkle_proofs (
  id SERIAL PRIMARY KEY,
  lock_hash VARCHAR(66) NOT NULL UNIQUE REFERENCES lock_events(lock_hash),
  proof JSONB NOT NULL,
  merkle_root VARCHAR(66) NOT NULL,
  block_number INTEGER NOT NULL,
  source_chain VARCHAR(20) NOT NULL,
  destination_chain VARCHAR(20) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lock_hash_proof ON merkle_proofs(lock_hash);
CREATE INDEX IF NOT EXISTS idx_block_number_proof ON merkle_proofs(block_number, source_chain);

-- Block roots submitted to destination chains
CREATE TABLE IF NOT EXISTS block_roots (
  id SERIAL PRIMARY KEY,
  block_number INTEGER NOT NULL,
  source_chain VARCHAR(20) NOT NULL,
  destination_chain VARCHAR(20) NOT NULL,
  merkle_root VARCHAR(66) NOT NULL,
  submitted BOOLEAN DEFAULT FALSE,
  submission_tx_hash VARCHAR(66),
  submission_timestamp TIMESTAMP,
  lock_count INTEGER DEFAULT 0,
  created_at TIMESTAMP DEFAULT NOW(),
  UNIQUE(block_number, source_chain, destination_chain)
);

CREATE INDEX IF NOT EXISTS idx_block_number_roots ON block_roots(block_number, source_chain);
CREATE INDEX IF NOT EXISTS idx_submitted ON block_roots(submitted);

-- Unlock transactions
CREATE TABLE IF NOT EXISTS unlock_events (
  id SERIAL PRIMARY KEY,
  lock_hash VARCHAR(66) NOT NULL REFERENCES lock_events(lock_hash),
  token_id INTEGER NOT NULL,
  recipient_address VARCHAR(42) NOT NULL,
  chain VARCHAR(20) NOT NULL,
  tx_hash VARCHAR(66) NOT NULL,
  block_number INTEGER NOT NULL,
  gas_used BIGINT,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'failed')),
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lock_hash_unlock ON unlock_events(lock_hash);
CREATE INDEX IF NOT EXISTS idx_tx_hash ON unlock_events(tx_hash);

-- Relayer transactions for monitoring
CREATE TABLE IF NOT EXISTS relayer_transactions (
  id SERIAL PRIMARY KEY,
  tx_hash VARCHAR(66) NOT NULL UNIQUE,
  chain VARCHAR(20) NOT NULL,
  tx_type VARCHAR(50) NOT NULL CHECK (tx_type IN ('submit_root', 'unlock_nft', 'batch_unlock')),
  block_number INTEGER,
  gas_used BIGINT,
  gas_price BIGINT,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'failed')),
  error_message TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  confirmed_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_tx_hash_relayer ON relayer_transactions(tx_hash);
CREATE INDEX IF NOT EXISTS idx_status_relayer ON relayer_transactions(status);
CREATE INDEX IF NOT EXISTS idx_chain_type ON relayer_transactions(chain, tx_type);

-- Token bridge history for analytics
CREATE TABLE IF NOT EXISTS bridge_history (
  id SERIAL PRIMARY KEY,
  token_id INTEGER NOT NULL,
  owner_address VARCHAR(42) NOT NULL,
  from_chain VARCHAR(20) NOT NULL,
  to_chain VARCHAR(20) NOT NULL,
  lock_tx_hash VARCHAR(66) NOT NULL,
  unlock_tx_hash VARCHAR(66),
  lock_timestamp TIMESTAMP NOT NULL,
  unlock_timestamp TIMESTAMP,
  duration_seconds INTEGER,
  status VARCHAR(20) NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress', 'completed', 'failed')),
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_token_history ON bridge_history(token_id);
CREATE INDEX IF NOT EXISTS idx_owner_history ON bridge_history(owner_address);
CREATE INDEX IF NOT EXISTS idx_status_history ON bridge_history(status);

-- System health metrics
CREATE TABLE IF NOT EXISTS system_metrics (
  id SERIAL PRIMARY KEY,
  metric_name VARCHAR(100) NOT NULL,
  metric_value NUMERIC NOT NULL,
  chain VARCHAR(20),
  recorded_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_metric_name ON system_metrics(metric_name);
CREATE INDEX IF NOT EXISTS idx_recorded_at ON system_metrics(recorded_at);

-- Failed transactions for retry
CREATE TABLE IF NOT EXISTS failed_transactions (
  id SERIAL PRIMARY KEY,
  tx_type VARCHAR(50) NOT NULL,
  chain VARCHAR(20) NOT NULL,
  payload JSONB NOT NULL,
  error_message TEXT,
  retry_count INTEGER DEFAULT 0,
  max_retries INTEGER DEFAULT 3,
  next_retry_at TIMESTAMP,
  resolved BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_next_retry ON failed_transactions(next_retry_at, resolved);
CREATE INDEX IF NOT EXISTS idx_resolved ON failed_transactions(resolved);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to lock_events
CREATE TRIGGER update_lock_events_updated_at
  BEFORE UPDATE ON lock_events
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- Views for common queries
CREATE OR REPLACE VIEW pending_locks AS
SELECT 
  le.*,
  mp.proof,
  mp.merkle_root,
  br.submitted as root_submitted
FROM lock_events le
LEFT JOIN merkle_proofs mp ON le.lock_hash = mp.lock_hash
LEFT JOIN block_roots br ON le.block_number = br.block_number 
  AND le.chain = br.source_chain
WHERE le.status IN ('pending', 'proof_generated', 'root_submitted')
ORDER BY le.created_at ASC;

CREATE OR REPLACE VIEW bridge_stats AS
SELECT 
  chain,
  COUNT(*) as total_locks,
  COUNT(CASE WHEN status = 'unlocked' THEN 1 END) as completed,
  COUNT(CASE WHEN status = 'pending' THEN 1 END) as pending,
  COUNT(CASE WHEN status = 'failed' THEN 1 END) as failed,
  AVG(EXTRACT(EPOCH FROM (updated_at - created_at))) as avg_duration_seconds
FROM lock_events
GROUP BY chain;
