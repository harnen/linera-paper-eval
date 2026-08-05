#![recursion_limit = "512"]

use anyhow::{Context as _, Error, Result, ensure};
use linera_base::crypto::InMemorySigner;
use linera_base::data_types::ChainDescription;
use linera_base::identifiers::ChainId;
use linera_base::{
    data_types::Amount,
    identifiers::{Account, AccountOwner},
};
use linera_client::{chain_listener::ClientContext as _, client_context::ClientContext};
use linera_core::client::ChainClient;
use linera_core::data_types::ClientOutcome;
use linera_core::environment::Impl;
use linera_core::wallet;
use linera_core::worker::{DEFAULT_BLOCK_CACHE_SIZE, DEFAULT_EXECUTION_STATE_CACHE_SIZE};
use linera_execution::{Operation, SystemOperation, WasmRuntime};
use linera_rpc::NodeProvider;
use linera_service::cli_wrappers::Faucet;
use linera_storage::{DbStorage, WallClock};
use linera_views::{
    backends::{
        lru_caching::LruCachingConfig,
        rocks_db::{PathWithGuard, RocksDbDatabase, RocksDbSpawnMode, RocksDbStoreInternalConfig},
    },
    lru_prefix_cache::StorageCacheConfig as ViewsStorageCacheConfig,
};
use linera_wallet_json::{Keystore, PersistentWallet};
use rand::prelude::SliceRandom;
use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use std::time::Duration;
use tokio::sync::broadcast::Receiver;
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tracing::{debug, error, info, warn};
use tracing_subscriber::{EnvFilter, fmt};

type RocksDbStorage = DbStorage<RocksDbDatabase, WallClock>;
type LContext = ClientContext<Impl<RocksDbStorage, NodeProvider, InMemorySigner, PersistentWallet>>;

fn initialize_logging() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,linera_paper_eval=debug"));

    fmt()
        .with_env_filter(env_filter)
        .with_target(true)
        .with_level(true)
        .init();
}

async fn create_rocksdb_storage(path: &Path) -> Result<RocksDbStorage> {
    let config = LruCachingConfig {
        inner_config: RocksDbStoreInternalConfig {
            path_with_guard: PathWithGuard::new(path.to_path_buf()),
            spawn_mode: RocksDbSpawnMode::get_spawn_mode_from_runtime(),
            enable_statistics: false,
            statistics_level: Default::default(),
        },
        storage_cache_config: ViewsStorageCacheConfig {
            max_cache_size: 10_000_000,
            max_value_entry_size: 1_000_000,
            max_find_keys_entry_size: 10_000_000,
            max_find_key_values_entry_size: 10_000_000,
            max_cache_entries: 1000, // TODO ?
            max_cache_value_size: 10_000_000,
            max_cache_find_keys_size: 10_000_000,
            max_cache_find_key_values_size: 10_000_000,
        },
    };

    let cache_sizes = linera_storage::StorageCacheConfig {
        blob_cache_size: 1000,
        confirmed_block_cache_size: 1000,
        certificate_cache_size: 1000,
        certificate_raw_cache_size: 1000,
        event_cache_size: 1000,
        block_hash_by_height_cache_size: 1000,
        event_block_height_cache_size: 1000,
        cache_cleanup_interval_secs: 30,
    };

    let storage = DbStorage::<RocksDbDatabase, _>::maybe_create_and_connect(
        &config,
        "linera_eval_client",
        Some(WasmRuntime::default()),
        cache_sizes,
    )
    .await?;

    Ok(storage)
}

fn eval_output_dir() -> String {
    std::env::var("EVAL_OUTPUT_DIR").unwrap_or_else(|_| "/data_out".to_string())
}

async fn set_up_chains(
    wallet: &PersistentWallet,
    keystore: &mut Keystore,
    num_chains: usize,
) -> Result<Vec<(ChainDescription, AccountOwner)>> {
    let faucet_url = std::env::var("FAUCET_URL").context("missing FAUCET_URL")?;
    let faucet = Faucet::new(faucet_url.clone());

    let mut chains = Vec::with_capacity(num_chains);
    for _i in 0..num_chains {
        let owner: AccountOwner = keystore.generate_key().await?.into();

        debug!(
            "Requesting a new chain for owner {} using the faucet {}",
            owner, &faucet_url
        );

        let description = faucet.claim(&owner).await?;

        ensure!(
            description.config().ownership.is_owner(&owner),
            "invalid faucet, chain not owned by us."
        );

        wallet.insert(
            description.id(),
            &wallet::Chain {
                owner: Some(owner),
                ..(&description).into()
            },
        )?;

        chains.push((description, owner));
    }

    Ok(chains)
}

#[tokio::main]
async fn main() -> Result<()> {
    initialize_logging();

    let experiment_configuration_suffix = std::env::var("EXPERIMENT_CONFIGURATION")
        .map(|s| format!("_{}", s))
        .unwrap_or("".to_string());

    let experiment_configuration =
        std::env::var("EXPERIMENT_CONFIGURATION").unwrap_or("".to_string());
    let repetition: u32 = std::env::var("EXPERIMENT_REPETITION")
        .context("missing EXPERIMENT_REPETITION")?
        .parse()
        .context("invalid EXPERIMENT_REPETITION")?;

    let wallet_path_s = std::env::var("LINERA_WALLET").context("missing LINERA_WALLET")?;
    let wallet_path = Path::new(wallet_path_s.as_str());
    let keystore_path_s = std::env::var("LINERA_KEYSTORE").context("missing LINERA_KEYSTORE")?;
    let keystore_path = Path::new(keystore_path_s.as_str());
    let storage_path_s = format!(
        "{}/eval-client.db",
        std::env::var("LINERA_TMP_DIR").context("missing LINERA_TMP_DIR")?
    );
    let storage_path = Path::new(storage_path_s.as_str());

    info!(
        wallet_path = %wallet_path.display(),
        keystore_path = %keystore_path.display(),
        storage_path = %storage_path.display(),
        "Starting Linera paper eval binary",
    );

    let mut keystore = Keystore::read(keystore_path).context("failed to read keystore")?;

    let wallet = PersistentWallet::read(wallet_path).context("failed to read wallet")?;
    info!(
        genesis_admin_chain_id = %wallet.genesis_admin_chain_id(),
        "Loaded wallet",
    );

    let mut storage = create_rocksdb_storage(storage_path).await?;

    wallet
        .genesis_config()
        .initialize_storage(&mut storage)
        .await
        .context("failed to initialize storage from genesis config")?;

    // We request all chains we're ever going to need upfront, because this generates new keys
    // and inserts them into the keystore.
    // We then turn the keystore into a Signer, which is passed into the client Context.
    // TODO figure out how to later generate new chains. And/or destroy chains.
    let mut chains = set_up_chains(&wallet, &mut keystore, 2 * 200 + 2).await?;

    let genesis_config = wallet.genesis_config().clone();
    let mut context = ClientContext::new(
        storage,
        wallet,
        keystore.into_signer(),
        &Default::default(),
        None,
        genesis_config,
        DEFAULT_BLOCK_CACHE_SIZE,
        DEFAULT_EXECUTION_STATE_CACHE_SIZE,
    )
    .await?;
    info!("created client context");

    // Run a transfer between two chains to see if stuff is working.
    run_two_chain_token_transfer(&mut context, chains.remove(0), chains.remove(0))
        .await
        .context("failed to run token transfer experiment")?;

    // Run the various experiments
    let mut chain_loop = chains.clone().into_iter().cycle();
    for num_chains in vec![ 10,2, 5, 20, 50, 100, 200] {
        for transfer_mode in vec![
            TransferTargetMode::RandomOtherChain,
            TransferTargetMode::SelfChain,
            TransferTargetMode::HalfAndHalfSelfOtherChain,
        ] {
            for num_tx_per_block in vec![1, 10, 100] {
                // Get a batch of chains to transfer between
                let batch: Vec<_> = chain_loop.by_ref().take(num_chains).collect();

                info!(
                    "running fire-and-forget experiment on {} chains, {} tx per block, transfer mode {:?}",
                    num_chains, num_tx_per_block, transfer_mode
                );
                run_many_chain_token_transfer_experiment(
                    batch.clone(),
                    &mut context,
                    transfer_mode,
                    &experiment_configuration,
                    repetition,
                    format!(
                        "{}_{:?}_{}tx{}_{}",
                        num_chains,
                        transfer_mode,
                        num_tx_per_block,
                        experiment_configuration_suffix,
                        repetition,
                    )
                    .as_str(),
                    num_tx_per_block,
                )
                .await
                .context("failed to run multi-chain transfer experiment")?;

                // Balance the chains
                // TODO maybe we can skip this now that we transfer tiny amounts.
                // TODO if we skip this, we can/should also skip the balance queries after the experiments
                // because they will be useless then.
                info!("balancing chains...");
                balance_chain_accounts(&mut context, &batch, Amount::from_tokens(1000))
                    .await
                    .context("unable to balance chains")?;

                let phase_2_batch: Vec<_> = chain_loop.by_ref().take(num_chains).collect();
                // TODO ensure! that there are no overlaps in the two batches.
                for target_bps in vec![1_u32, 2, 5, 10] {
                    info!(
                        "running paced experiment on {} chains, {} tx per block, transfer mode {:?}, target BPS {}",
                        num_chains, num_tx_per_block, transfer_mode, target_bps
                    );
                    run_two_phase_constant_bps_experiment(
                        batch.clone(),
                        phase_2_batch.clone(),
                        target_bps,
                        &mut context,
                        transfer_mode,
                        &experiment_configuration,
                        repetition,
                        format!(
                            "{}_{:?}_{}tx_{}bps{}_{}",
                            num_chains,
                            transfer_mode,
                            num_tx_per_block,
                            target_bps,
                            experiment_configuration_suffix,
                            repetition,
                        )
                        .as_str(),
                        num_tx_per_block,
                    )
                    .await
                    .context("failed to run two-phase transfer experiment")?;

                    // Balance the chains
                    // TODO maybe we can skip this now that we transfer tiny amounts.
                    // TODO if we skip this, we can/should also skip the balance queries after the experiments
                    // because they will be useless then.
                    info!("balancing chains...");
                    balance_chain_accounts(&mut context, &batch, Amount::from_tokens(1000))
                        .await
                        .context("unable to balance chains")?;
                    balance_chain_accounts(&mut context, &phase_2_batch, Amount::from_tokens(1000))
                        .await
                        .context("unable to balance chains")?;
                }
            }
        }
    }

    info!("done :)");

    Ok(())
}

#[derive(Clone, Copy, Debug)]
enum TransferTargetMode {
    RandomOtherChain,
    HalfAndHalfSelfOtherChain,
    SelfChain,
}

async fn run_two_chain_token_transfer(
    context: &mut LContext,
    first_chain: (ChainDescription, AccountOwner),
    second_chain: (ChainDescription, AccountOwner),
) -> Result<(), Error> {
    let amount = Amount::from_tokens(10);
    let (source_chain, source_owner) = first_chain;
    let source_chain_id = source_chain.id();
    let (destination_chain, _destination_owner) = second_chain;
    let destination_chain_id = destination_chain.id();

    let source_chain_client = context
        .make_chain_client(source_chain_id)
        .await
        .context("failed to create source chain client")?;

    info!(?source_chain, "Synchronizing source chain");
    source_chain_client
        .synchronize_from_validators()
        .await
        .context("failed to synchronize source chain")?;

    let source_chain_balance = source_chain_client
        .query_owner_balance(AccountOwner::CHAIN)
        .await
        .context("failed to query source chain account balance")?;

    let source_owner_balance = source_chain_client
        .query_owner_balance(source_owner.clone())
        .await
        .context("failed to query source owner account balance")?;

    info!(
        %source_chain_id,
        chain_account = %AccountOwner::CHAIN,
        %source_chain_balance,
        %source_owner,
        %source_owner_balance,
        "Source balances before transfer",
    );

    let recipient = Account::chain(destination_chain_id);

    info!(
        sender = %Account::chain(source_chain_id),
        %recipient,
        %amount,
        "Submitting native token transfer from chain account",
    );

    let certificate = context
        .apply_client_command(&source_chain_client, |chain| {
            let chain = chain.clone();
            let recipient = recipient;
            async move { chain.transfer(AccountOwner::CHAIN, amount, recipient).await }
        })
        .await
        .context("transfer failed")?;

    info!(
        certificate_hash = %certificate.hash(),
        "Transfer committed",
    );
    debug!(?certificate, "Transfer certificate");

    let source_chain_balance_after = source_chain_client
        .query_owner_balance(AccountOwner::CHAIN)
        .await
        .context("failed to query source chain account balance after transfer")?;

    info!(
        %source_chain_id,
        chain_account = %AccountOwner::CHAIN,
        %source_chain_balance_after,
        "Source chain-account balance after transfer",
    );

    let destination_chain = context
        .make_chain_client(destination_chain_id)
        .await
        .context("failed to create destination chain client")?;

    info!(%destination_chain_id, "Synchronizing destination chain");
    destination_chain
        .synchronize_from_validators()
        .await
        .context("failed to synchronize destination chain")?;

    let destination_chain_balance_before_inbox = destination_chain
        .query_owner_balance(AccountOwner::CHAIN)
        .await
        .context("failed to query destination chain account balance before inbox processing")?;

    info!(
        %destination_chain_id,
        chain_account = %AccountOwner::CHAIN,
        %destination_chain_balance_before_inbox,
        "Destination chain-account balance before inbox processing",
    );

    info!(%destination_chain_id, "Processing destination inbox");
    let inbox_certificates = context
        .process_inbox(&destination_chain)
        .await
        .context("failed to process destination inbox")?;

    info!(
        processed_blocks = inbox_certificates.len(),
        "Processed destination inbox",
    );
    debug!(?inbox_certificates, "Destination inbox certificates");

    let destination_chain_balance_after_inbox = destination_chain
        .query_owner_balance(AccountOwner::CHAIN)
        .await
        .context("failed to query destination chain account balance after inbox processing")?;

    info!(
        %destination_chain_id,
        chain_account = %AccountOwner::CHAIN,
        %destination_chain_balance_after_inbox,
        "Destination chain-account balance after inbox processing",
    );
    Ok(())
}

async fn run_two_phase_constant_bps_experiment(
    phase_1_chains: Vec<(ChainDescription, AccountOwner)>,
    phase_2_chains: Vec<(ChainDescription, AccountOwner)>,
    target_bps_per_chain: u32,
    context: &mut LContext,
    transfer_mode: TransferTargetMode,
    network_config: &str,
    repetition: u32,
    experiment_name: &str,
    tx_per_block: usize,
) -> Result<(), Error> {
    let outdir = format!("{}/two_phase/{}", eval_output_dir(), experiment_name);
    // Create output directory
    tokio::fs::create_dir_all(outdir.clone())
        .await
        .context("unable to create output directory")?;

    // Set up some plumbing
    let phase_1_start = Arc::new(tokio::sync::Barrier::new(phase_1_chains.len() + 1));
    let phase_2_start = Arc::new(tokio::sync::Barrier::new(phase_2_chains.len() + 1));
    let phase_1_stop = tokio_util::sync::CancellationToken::new();
    let phase_2_stop = tokio_util::sync::CancellationToken::new();
    let mut join_handles = Vec::new();

    // Build worker tasks
    info!("building workers...");
    for (desc, _) in phase_1_chains.iter() {
        let source_chain = context
            .make_chain_client(desc.id())
            .await
            .context("failed to create source chain client")?;
        source_chain.synchronize_from_validators().await?;
        context.update_wallet_from_client(&source_chain).await?;

        let destinations = phase_1_chains
            .iter()
            .map(|(desc, _)| desc.id())
            .filter(|d2| desc.id() != *d2)
            .collect::<Vec<_>>();

        let phase_1_start = phase_1_start.clone();
        let phase_1_stop = phase_1_stop.clone();
        let transfer_mode = transfer_mode;
        let tx_per_block = tx_per_block;
        let target_bps = target_bps_per_chain;

        let join_handle = tokio::spawn(async move {
            token_transfer_task_constant_bps(
                source_chain,
                destinations,
                phase_1_start,
                phase_1_stop,
                transfer_mode,
                tx_per_block,
                target_bps,
            )
            .await
        });

        join_handles.push(join_handle);
    }
    for (desc, _) in phase_2_chains.iter() {
        let source_chain = context
            .make_chain_client(desc.id())
            .await
            .context("failed to create source chain client")?;
        source_chain.synchronize_from_validators().await?;
        context.update_wallet_from_client(&source_chain).await?;

        let destinations = phase_2_chains
            .iter()
            .map(|(desc, _)| desc.id())
            .filter(|d2| desc.id() != *d2)
            .collect::<Vec<_>>();

        let phase_2_start = phase_2_start.clone();
        let phase_2_stop = phase_2_stop.clone();
        let transfer_mode = transfer_mode;
        let tx_per_block = tx_per_block;
        let target_bps = target_bps_per_chain;

        let join_handle = tokio::spawn(async move {
            token_transfer_task_constant_bps(
                source_chain,
                destinations,
                phase_2_start,
                phase_2_stop,
                transfer_mode,
                tx_per_block,
                target_bps,
            )
            .await
        });

        join_handles.push(join_handle);
    }

    // Start the experiment
    info!("starting phase one of the experiment...");
    let experiment_start = Instant::now();
    phase_1_start.wait().await;

    // Sleep for some time
    tokio::time::sleep(Duration::from_secs(30)).await;

    if !phase_2_chains.is_empty() {
        // Start the second phase, i.e., more chains
        info!("starting phase two of the experiment...");
        phase_2_start.wait().await;

        // Sleep for some time
        tokio::time::sleep(Duration::from_secs(30)).await;

        // Stop the additional chains
        info!("stopping phase two of the experiment...");
        phase_2_stop.cancel();
    }

    // Sleep for some time
    tokio::time::sleep(Duration::from_secs(30)).await;

    // Stop the remaining chains
    info!("stopping phase one of the experiment...");
    phase_1_stop.cancel();

    // Check the balances
    info!("Synchronizing chains and checking final balances...");
    let all_chains = phase_1_chains
        .clone()
        .into_iter()
        .chain(phase_2_chains.clone().into_iter())
        .collect::<Vec<_>>();
    compute_and_save_chain_balances(
        &all_chains,
        context,
        transfer_mode,
        network_config,
        repetition,
        experiment_name,
        &outdir,
    )
    .await
    .context("unable to query final balances")?;

    // Collect timings
    info!("collecting timings and writing CSV...");
    collect_and_persist_timings(
        &all_chains,
        phase_1_chains.len(),
        target_bps_per_chain,
        transfer_mode,
        network_config,
        repetition,
        experiment_name,
        tx_per_block,
        &outdir,
        experiment_start,
        join_handles,
    )
    .await
    .context("unable to collect timings and write CSV")?;

    Ok(())
}

async fn run_many_chain_token_transfer_experiment(
    chains: Vec<(ChainDescription, AccountOwner)>,
    context: &mut LContext,
    transfer_mode: TransferTargetMode,
    network_config: &str,
    repetition: u32,
    experiment_name: &str,
    tx_per_block: usize,
) -> Result<(), Error> {
    let outdir = format!("{}/many_chains/{}", eval_output_dir(), experiment_name);
    // Create output directory
    tokio::fs::create_dir_all(outdir.clone())
        .await
        .context("unable to create output directory")?;

    // Set up some plumbing
    let (start_stop_tx, start_stop_rx) = tokio::sync::broadcast::channel(1);
    let mut join_handles = Vec::new();

    // Build worker tasks
    info!("building workers...");
    for (desc, _) in chains.iter() {
        let source_chain = context
            .make_chain_client(desc.id())
            .await
            .context("failed to create source chain client")?;
        source_chain.synchronize_from_validators().await?;
        context.update_wallet_from_client(&source_chain).await?;

        let destinations = chains
            .iter()
            .map(|(desc, _)| desc.id())
            .filter(|d2| desc.id() != *d2)
            .collect::<Vec<_>>();

        let start_stop_rx = start_stop_tx.subscribe();
        let transfer_mode = transfer_mode;
        let tx_per_block = tx_per_block;

        let join_handle = tokio::spawn(async move {
            token_transfer_task(
                source_chain,
                destinations,
                start_stop_rx,
                transfer_mode,
                tx_per_block,
            )
            .await
        });

        join_handles.push(join_handle);
    }

    // Don't need this anymore...
    drop(start_stop_rx);

    // Start the experiment
    info!("starting the experiment...");
    let experiment_start = Instant::now();
    start_stop_tx
        .send(())
        .context("unable to send on broadcast channel")?;

    // Sleep for some time
    tokio::time::sleep(Duration::from_secs(60)).await;

    // Stop the experiment
    info!("stopping the experiment...");
    start_stop_tx
        .send(())
        .context("unable to send on broadcast channel")?;

    // Check the balances
    info!("Synchronizing chains and checking final balances...");
    compute_and_save_chain_balances(
        &chains,
        context,
        transfer_mode,
        network_config,
        repetition,
        experiment_name,
        &outdir,
    )
    .await
    .context("unable to query final balances")?;

    // Collect timings
    info!("collecting timings and writing CSV...");
    collect_and_persist_timings(
        &chains,
        chains.len(),
        0,
        transfer_mode,
        network_config,
        repetition,
        experiment_name,
        tx_per_block,
        &outdir,
        experiment_start,
        join_handles,
    )
    .await?;

    Ok(())
}

async fn collect_and_persist_timings(
    chains: &[(ChainDescription, AccountOwner)],
    num_phase1_chains: usize,
    target_bps: u32,
    transfer_mode: TransferTargetMode,
    network_config: &str,
    repetition: u32,
    experiment_name: &str,
    tx_per_block: usize,
    outdir: &str,
    experiment_start: Instant,
    join_handles: Vec<
        JoinHandle<(
            Vec<(Instant, Duration)>,
            Vec<(Instant, Duration)>,
            Vec<(Instant, Duration)>,
            Vec<(Instant, Duration)>,
        )>,
    >,
) -> Result<(), Error> {
    let mut total_committed = 0;
    let mut total_wait_for_timeout = 0;
    let mut total_conflict = 0;
    let mut total_error = 0;
    let mut total_committed_duration = Duration::from_secs(0);
    let mut total_wait_for_timeout_duration = Duration::from_secs(0);
    let mut total_conflict_duration = Duration::from_secs(0);
    let mut total_error_duration = Duration::from_secs(0);

    {
        let mut out_writer = {
            let outfile = tokio::fs::File::create(format!("{}/transfers.csv", outdir))
                .await
                .context("unable to create transfers file")?;
            csv_async::AsyncWriter::from_writer(outfile)
        };
        out_writer
            .write_record(&[
                "experiment",
                "num_chains",
                "transfer_mode",
                "network_config",
                "target_bps",
                "repetition",
                "chain_id",
                "phase",
                "ts_within_experiment",
                "num_tx",
                "result",
                "duration_micros",
            ])
            .await
            .context("unable to write result CSV")?;

        for (i, (handle, (desc, _))) in join_handles.into_iter().zip(chains.iter()).enumerate() {
            let chain_id = desc.id();
            let phase = if i >= num_phase1_chains { 2 } else { 1 };
            let (committed, wait_for_timeout, conflict, error) =
                handle.await.context("sending task failed")?;

            total_committed += committed.len();
            total_wait_for_timeout += wait_for_timeout.len();
            total_conflict += conflict.len();
            total_error += error.len();

            for (before, dur) in committed.into_iter() {
                let ts = before - experiment_start;
                out_writer
                    .write_record(&[
                        experiment_name.to_string(),
                        format!("{}", chains.len()),
                        format!("{:?}", transfer_mode),
                        network_config.to_string(),
                        format!("{}", target_bps),
                        format!("{}", repetition),
                        chain_id.to_string(),
                        format!("{}", phase),
                        format!("{}", ts.as_secs_f64()),
                        format!("{}", tx_per_block),
                        "committed".to_string(),
                        format!("{}", dur.as_micros()),
                    ])
                    .await
                    .context("unable to write result CSV")?;
                total_committed_duration += dur;
            }
            for (before, dur) in wait_for_timeout.into_iter() {
                let ts = before - experiment_start;
                out_writer
                    .write_record(&[
                        experiment_name.to_string(),
                        format!("{}", chains.len()),
                        format!("{:?}", transfer_mode),
                        network_config.to_string(),
                        format!("{}", target_bps),
                        format!("{}", repetition),
                        chain_id.to_string(),
                        format!("{}", phase),
                        format!("{}", ts.as_secs_f64()),
                        format!("{}", tx_per_block),
                        "wait_for_timeout".to_string(),
                        format!("{}", dur.as_micros()),
                    ])
                    .await
                    .context("unable to write result CSV")?;
                total_wait_for_timeout_duration += dur;
            }
            for (before, dur) in conflict.into_iter() {
                let ts = before - experiment_start;
                out_writer
                    .write_record(&[
                        experiment_name.to_string(),
                        format!("{}", chains.len()),
                        format!("{:?}", transfer_mode),
                        network_config.to_string(),
                        format!("{}", target_bps),
                        format!("{}", repetition),
                        chain_id.to_string(),
                        format!("{}", phase),
                        format!("{}", ts.as_secs_f64()),
                        format!("{}", tx_per_block),
                        "conflict".to_string(),
                        format!("{}", dur.as_micros()),
                    ])
                    .await
                    .context("unable to write result CSV")?;
                total_conflict_duration += dur;
            }
            for (before, dur) in error.into_iter() {
                let ts = before - experiment_start;
                out_writer
                    .write_record(&[
                        experiment_name.to_string(),
                        format!("{}", chains.len()),
                        format!("{:?}", transfer_mode),
                        network_config.to_string(),
                        format!("{}", target_bps),
                        format!("{}", repetition),
                        chain_id.to_string(),
                        format!("{}", phase),
                        format!("{}", ts.as_secs_f64()),
                        format!("{}", tx_per_block),
                        "error".to_string(),
                        format!("{}", dur.as_micros()),
                    ])
                    .await
                    .context("unable to write result CSV")?;
                total_error_duration += dur;
            }
        }
    }
    info!(
        "total committed: {}, total wait_for_timeout: {}, total conflict: {}, total error: {}",
        total_committed, total_wait_for_timeout, total_conflict, total_error
    );
    if total_committed != 0 {
        info!(
            "committed mean {} µs",
            total_committed_duration.as_micros() as f64 / total_committed as f64
        );
    }
    if total_wait_for_timeout != 0 {
        info!(
            "wait_for_timeout mean {} µs",
            total_wait_for_timeout_duration.as_micros() as f64 / total_wait_for_timeout as f64
        );
    }
    if total_conflict != 0 {
        info!(
            "conflict mean {} µs",
            total_conflict_duration.as_micros() as f64 / total_conflict as f64
        );
    }
    if total_error != 0 {
        info!(
            "error mean {} µs",
            total_error_duration.as_micros() as f64 / total_error as f64
        );
    }
    Ok(())
}

async fn compute_and_save_chain_balances(
    chains: &[(ChainDescription, AccountOwner)],
    context: &mut LContext,
    transfer_mode: TransferTargetMode,
    network_config: &str,
    repetition: u32,
    experiment_name: &str,
    outdir: &str,
) -> Result<(), Error> {
    let mut total = Amount::ZERO;
    {
        let mut out_writer = {
            let outfile = tokio::fs::File::create(format!("{}/balances.csv", outdir))
                .await
                .context("unable to create balances file")?;
            csv_async::AsyncWriter::from_writer(outfile)
        };
        out_writer
            .write_record(&[
                "experiment",
                "num_chains",
                "transfer_mode",
                "network_config",
                "repetition",
                "chain_id",
                "chain_account",
                "when",
                "balance",
            ])
            .await
            .context("unable to write result CSV")?;

        // TODO make this parallel somehow, but the inbox processing needs a mutable(!) reference to the context, wtf
        for (desc, _) in chains.iter() {
            let destination_chain_id = desc.id();
            let destination_chain = context
                .make_chain_client(destination_chain_id)
                .await
                .context("failed to create destination chain client")?;

            debug!(%destination_chain_id, "Synchronizing destination chain");
            destination_chain
                .synchronize_from_validators()
                .await
                .context("failed to synchronize destination chain")?;
/*
            let destination_chain_balance_before_inbox = destination_chain
                .query_owner_balance(AccountOwner::CHAIN)
                .await
                .context(
                    "failed to query destination chain account balance before inbox processing",
                )?;

            debug!(
                %destination_chain_id,
                chain_account = %AccountOwner::CHAIN,
                %destination_chain_balance_before_inbox,
                "Destination chain-account balance before inbox processing",
            );
            out_writer
                .write_record(&[
                    experiment_name,
                    format!("{}", chains.len()).as_str(),
                    format!("{:?}", transfer_mode).as_str(),
                    network_config,
                    format!("{}", repetition).as_str(),
                    destination_chain_id.to_string().as_str(),
                    "CHAIN",
                    "before_inbox",
                    destination_chain_balance_before_inbox.to_string().as_str(),
                ])
                .await
                .context("unable to write result CSV")?;
*/
            debug!(%destination_chain_id, "Processing destination inbox");
            let inbox_certificates = context
                .process_inbox(&destination_chain)
                .await
                .context("failed to process destination inbox")?;

            debug!(
                processed_blocks = inbox_certificates.len(),
                "Processed destination inbox",
            );
            debug!(?inbox_certificates, "Destination inbox certificates");

            let destination_chain_balance_after_inbox = destination_chain
                .query_owner_balance(AccountOwner::CHAIN)
                .await
                .context(
                    "failed to query destination chain account balance after inbox processing",
                )?;

            (&mut total).saturating_add_assign(destination_chain_balance_after_inbox);

            debug!(
                %destination_chain_id,
                chain_account = %AccountOwner::CHAIN,
                %destination_chain_balance_after_inbox,
                "Destination chain-account balance after inbox processing",
            );
            out_writer
                .write_record(&[
                    experiment_name,
                    format!("{}", chains.len()).as_str(),
                    format!("{:?}", transfer_mode).as_str(),
                    network_config,
                    format!("{}", repetition).as_str(),
                    destination_chain_id.to_string().as_str(),
                    "CHAIN",
                    "after_inbox",
                    destination_chain_balance_after_inbox.to_string().as_str(),
                ])
                .await
                .context("unable to write result CSV")?;

            let chain_info = destination_chain
                .chain_info()
                .await
                .context("failed to query chain info")?;
            debug!(
                %destination_chain_id,
                ?chain_info,
                "chain info",
            )
        }
    }

    info!(
        "total amount across all chains: {}, expected: {}",
        total,
        Amount::from_tokens(1000).saturating_mul(chains.len() as u128)
    );
    Ok(())
}

async fn token_transfer_task(
    source_chain: ChainClient<Impl<RocksDbStorage, NodeProvider, InMemorySigner, PersistentWallet>>,
    destinations: Vec<ChainId>,
    mut start_stop_rx: Receiver<()>,
    transfer_mode: TransferTargetMode,
    tx_per_block: usize,
) -> (
    Vec<(Instant, Duration)>,
    Vec<(Instant, Duration)>,
    Vec<(Instant, Duration)>,
    Vec<(Instant, Duration)>,
) {
    let amount = Amount::from_attos(1);

    // Collect timings
    let mut committed = Vec::new();
    let mut wait_for_timeout = Vec::new();
    let mut conflict = Vec::new();
    let mut error = Vec::new();

    // Prepare an iterator of destinations based on the transfer mode.
    // This way we don't have to randomly pick on every iteration.
    let mut destinations: Box<dyn Iterator<Item = ChainId> + Send> = {
        let own_chain = source_chain.chain_id();
        let mut rng = rand::rng();
        // Filter out the source chain
        let mut destinations = destinations;
        destinations.shuffle(&mut rng);

        match transfer_mode {
            TransferTargetMode::RandomOtherChain => Box::new(destinations.into_iter().cycle()),
            TransferTargetMode::HalfAndHalfSelfOtherChain => Box::new(
                destinations
                    .into_iter()
                    .flat_map(move |x| [x, own_chain])
                    .cycle(),
            ),
            TransferTargetMode::SelfChain => Box::new([own_chain].into_iter().cycle()),
        }
    };

    // Wait for the start signal
    let _ = start_stop_rx.recv().await;

    // We need this pinned to poll for the stop signal.
    // Not elegant, but works, I guess...
    let mut receiver = Box::pin(start_stop_rx.recv());

    // Send stuff
    loop {
        // Get a bunch of destinations to send to,
        // then build transfers.
        let operations = destinations
            .by_ref()
            .take(tx_per_block)
            .map(|dest| {
                Operation::system(SystemOperation::Transfer {
                    owner: AccountOwner::CHAIN,
                    recipient: Account::chain(dest),
                    amount,
                })
            })
            .collect::<Vec<_>>();

        // Check for shutdown
        let res = {
            let mut context = Context::from_waker(Waker::noop());
            receiver.as_mut().poll(&mut context)
        };
        if let Poll::Ready(_) = res {
            break;
        }

        // Attempt to transfer
        let before = Instant::now();
        let tx_res = source_chain
            .execute_operations(operations, Vec::new())
            .await;
        let time_diff = before.elapsed();

        // Timestamp within the experiment run.
        match tx_res {
            Ok(res) => match res {
                ClientOutcome::Committed(_) => {
                    committed.push((before, time_diff));
                }
                ClientOutcome::WaitForTimeout(e) => {
                    info!(
                        "wait for timeout for transfer from chain {}: {:?}",
                        source_chain.chain_id(),
                        e
                    );
                    wait_for_timeout.push((before, time_diff));
                }
                ClientOutcome::Conflict(e) => {
                    warn!(
                        "conflict for transfer from chain {}: {:?}",
                        source_chain.chain_id(),
                        e
                    );
                    conflict.push((before, time_diff));
                }
            },
            Err(e) => {
                error!(
                    "failed to send from chain {}: {:?}",
                    source_chain.chain_id(),
                    e
                );
                error.push((before, time_diff));
            }
        }
    }

    (committed, wait_for_timeout, conflict, error)
}

async fn token_transfer_task_constant_bps(
    source_chain: ChainClient<Impl<RocksDbStorage, NodeProvider, InMemorySigner, PersistentWallet>>,
    destinations: Vec<ChainId>,
    start_signal: Arc<tokio::sync::Barrier>,
    stop_signal: tokio_util::sync::CancellationToken,
    transfer_mode: TransferTargetMode,
    tx_per_block: usize,
    target_bps: u32,
) -> (
    Vec<(Instant, Duration)>,
    Vec<(Instant, Duration)>,
    Vec<(Instant, Duration)>,
    Vec<(Instant, Duration)>,
) {
    let amount = Amount::from_attos(1);

    // Collect timings
    let mut committed = Vec::new();
    let mut wait_for_timeout = Vec::new();
    let mut conflict = Vec::new();
    let mut error = Vec::new();

    // Prepare an infinite iterator of destinations based on the transfer mode.
    // This way we don't have to randomly pick on every iteration.
    let mut destinations: Box<dyn Iterator<Item = ChainId> + Send> = {
        let own_chain = source_chain.chain_id();
        let mut rng = rand::rng();
        // Filter out the source chain
        let mut destinations = destinations;
        destinations.shuffle(&mut rng);

        match transfer_mode {
            TransferTargetMode::RandomOtherChain => Box::new(destinations.into_iter().cycle()),
            TransferTargetMode::HalfAndHalfSelfOtherChain => Box::new(
                destinations
                    .into_iter()
                    .flat_map(move |x| [x, own_chain])
                    .cycle(),
            ),
            TransferTargetMode::SelfChain => Box::new([own_chain].into_iter().cycle()),
        }
    };

    // Wait for the start signal
    start_signal.wait().await;

    // Sleep a bit to de-sync
    tokio::time::sleep(Duration::from_millis(rand::random::<u64>() % 1000)).await;

    // Ticker for target bps
    let mut ticker = tokio::time::interval(Duration::from_millis(1000 / target_bps as u64));
    // First tick is free, yay
    ticker.tick().await;

    // Send stuff
    loop {
        // Get a bunch of destinations to send to,
        // then build transfers.
        let operations = destinations
            .by_ref()
            .take(tx_per_block)
            .map(|dest| {
                Operation::system(SystemOperation::Transfer {
                    owner: AccountOwner::CHAIN,
                    recipient: Account::chain(dest),
                    amount,
                })
            })
            .collect::<Vec<_>>();

        // Wait for a tick or shutdown
        tokio::select! {
            _ = ticker.tick() => {}
            _ = stop_signal.cancelled() => {
                break
            }
        }

        // Attempt to transfer
        let before = Instant::now();
        let tx_res = source_chain
            .execute_operations(operations, Vec::new())
            .await;
        let time_diff = before.elapsed();

        // Timestamp within the experiment run.
        match tx_res {
            Ok(res) => match res {
                ClientOutcome::Committed(_) => {
                    committed.push((before, time_diff));
                }
                ClientOutcome::WaitForTimeout(e) => {
                    info!(
                        "wait for timeout for transfer from chain {}: {:?}",
                        source_chain.chain_id(),
                        e
                    );
                    wait_for_timeout.push((before, time_diff));
                }
                ClientOutcome::Conflict(e) => {
                    warn!(
                        "conflict for transfer from chain {}: {:?}",
                        source_chain.chain_id(),
                        e
                    );
                    conflict.push((before, time_diff));
                }
            },
            Err(e) => {
                error!(
                    "failed to send from chain {}: {:?}",
                    source_chain.chain_id(),
                    e
                );
                error.push((before, time_diff));
            }
        }
    }

    (committed, wait_for_timeout, conflict, error)
}

async fn balance_chain_accounts(
    context: &mut LContext,
    chains: &[(ChainDescription, AccountOwner)],
    target_balance: Amount,
) -> Result<()> {
    let chain_ids = chains.iter().map(|(desc, _)| desc.id()).collect::<Vec<_>>();
    let unique_chain_ids: HashSet<_> = chain_ids.iter().copied().collect();
    ensure!(
        unique_chain_ids.len() == chain_ids.len(),
        "chain list contains duplicate chain IDs"
    );

    // First, settle all pending incoming transfers and obtain canonical balances.
    let mut balances = Vec::with_capacity(chain_ids.len());
    let mut total_balance = Amount::ZERO;

    for &chain_id in chain_ids.iter() {
        let chain = context
            .make_chain_client(chain_id)
            .await
            .with_context(|| format!("failed to create client for chain {chain_id}"))?;

        context
            .process_inbox(&chain)
            .await
            .with_context(|| format!("failed to process inbox for chain {chain_id}"))?;

        let balance = chain
            .query_owner_balance(AccountOwner::CHAIN)
            .await
            .with_context(|| {
                format!("failed to query chain-account balance for chain {chain_id}")
            })?;

        total_balance
            .try_add_assign(balance)
            .context("total chain balance overflowed")?;

        balances.push((chain_id, balance));
    }

    let required_total = target_balance
        .try_mul(chain_ids.len() as u128)
        .context("required total balance overflowed")?;

    // With no mint, burn, or external reserve account, redistribution is only
    // possible if the exact required amount is already present.
    ensure!(
        total_balance == required_total,
        "cannot balance {} chains to {} each: current total is {}, required total is {}",
        chain_ids.len(),
        target_balance,
        total_balance,
        required_total,
    );

    let mut donors = Vec::new();
    let mut recipients = Vec::new();

    for (chain_id, balance) in balances {
        if balance > target_balance {
            donors.push((
                chain_id,
                balance
                    .try_sub(target_balance)
                    .context("failed to calculate surplus")?,
            ));
        } else if balance < target_balance {
            recipients.push((
                chain_id,
                target_balance
                    .try_sub(balance)
                    .context("failed to calculate deficit")?,
            ));
        }
    }

    let mut recipient_index = 0;

    for (source_chain_id, mut surplus) in donors {
        let source_chain = context
            .make_chain_client(source_chain_id)
            .await
            .with_context(|| {
                format!("failed to create source client for chain {source_chain_id}")
            })?;

        while surplus > Amount::ZERO {
            let (destination_chain_id, deficit) = recipients
                .get(recipient_index)
                .copied()
                .context("ran out of recipient chains while balancing")?;

            let transfer_amount = std::cmp::min(surplus, deficit);
            let recipient = Account::chain(destination_chain_id);

            info!(
                %source_chain_id,
                %destination_chain_id,
                amount = %transfer_amount,
                "Balancing chain accounts",
            );

            context
                .apply_client_command(&source_chain, |chain| {
                    let chain = chain.clone();
                    let recipient = recipient.clone();

                    async move {
                        chain
                            .transfer(AccountOwner::CHAIN, transfer_amount, recipient)
                            .await
                    }
                })
                .await
                .with_context(|| {
                    format!(
                        "failed to transfer {transfer_amount} from \
                         {source_chain_id} to {destination_chain_id}"
                    )
                })?;

            surplus
                .try_sub_assign(transfer_amount)
                .context("failed to update donor surplus")?;

            recipients[recipient_index]
                .1
                .try_sub_assign(transfer_amount)
                .context("failed to update recipient deficit")?;

            if recipients[recipient_index].1 == Amount::ZERO {
                recipient_index += 1;
            }
        }
    }

    ensure!(
        recipient_index == recipients.len(),
        "some chain deficits remained after balancing"
    );

    // Commit the incoming credits and verify the result.
    for &chain_id in chain_ids.iter() {
        let chain = context
            .make_chain_client(chain_id)
            .await
            .with_context(|| format!("failed to recreate client for chain {chain_id}"))?;

        context.process_inbox(&chain).await.with_context(|| {
            format!("failed to process balancing transfers for chain {chain_id}")
        })?;

        let final_balance = chain
            .query_owner_balance(AccountOwner::CHAIN)
            .await
            .with_context(|| format!("failed to verify balance for chain {chain_id}"))?;

        ensure!(
            final_balance == target_balance,
            "chain {} has balance {} after balancing; expected {}",
            chain_id,
            final_balance,
            target_balance,
        );
    }

    info!(
        chain_count = chain_ids.len(),
        %target_balance,
        "Finished balancing chain accounts",
    );

    Ok(())
}
