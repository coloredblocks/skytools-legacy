-- ----------------------------------------------------------------------
-- Section: Internal Tables
--
-- Overview:
--      pgq.queue                   - Queue configuration
--      pgq.consumer                - Consumer names
--      pgq.subscription            - Consumer registrations
--      pgq.tick                    - Per-queue snapshots (ticks)
--      pgq.event_*                 - Data tables
--      pgq.retry_queue             - Events to be retried later
--      pgq.failed_queue            - Events whose processing failed
--
-- Its basically generalized and simplified Slony-I structure:
--      sl_node                     - pgq.consumer
--      sl_set                      - pgq.queue
--      sl_subscriber + sl_confirm  - pgq.subscription
--      sl_event                    - pgq.tick
--      sl_setsync                  - pgq_ext.completed_*
--      sl_log_*                    - slony1 has per-cluster data tables,
--                                    pgq has per-queue data tables.
-- ----------------------------------------------------------------------

set client_min_messages = 'warning';

-- drop schema if exists pgq cascade;
create schema pgq;
grant usage on schema pgq to public;

-- ----------------------------------------------------------------------
-- Table: pgq.consumer
--
--      Name to id lookup for consumers
--
-- Columns:
--      co_id       - consumer's id for internal usage
--      co_name     - consumer's id for external usage
-- ----------------------------------------------------------------------
create table pgq.consumer (
	co_id       serial,
	co_name     text        not null default 'fooz',

	constraint consumer_pkey primary key (co_id),
	constraint consumer_name_uq UNIQUE (co_name)
);


-- ----------------------------------------------------------------------
-- Table: pgq.queue
--
--     Information about available queues
--
-- Columns:
--      queue_id                    - queue id for internal usage
--      queue_name                  - queue name visible outside
--      queue_data                  - parent table for actual data tables
--      queue_switch_step1          - tx when rotation happened
--      queue_switch_step2          - tx after rotation was committed
--      queue_switch_time           - time when switch happened
--      queue_ticker_max_count      - batch should not contain more events
--      queue_ticker_max_lag        - events should not age more
--      queue_ticker_idle_period    - how often to tick when no events happen
-- ----------------------------------------------------------------------
create table pgq.queue (
	queue_id		    serial,
	queue_name		    text        not null,

        queue_ntables               integer     not null default 3,
        queue_cur_table             integer     not null default 0,
        queue_rotation_period       interval    not null default '2 hours',
	queue_switch_step1          bigint      not null default get_current_txid(),
	queue_switch_step2          bigint               default get_current_txid(),
        queue_switch_time           timestamptz not null default now(),

        queue_external_ticker       boolean     not null default false,
        queue_ticker_max_count      integer     not null default 500,
        queue_ticker_max_lag        interval    not null default '3 seconds',
        queue_ticker_idle_period    interval    not null default '1 minute',

        queue_data_pfx              text        not null,
        queue_event_seq             text        not null,
        queue_tick_seq              text        not null,

	constraint queue_pkey primary key (queue_id),
	constraint queue_name_uq unique (queue_name)
);

-- ----------------------------------------------------------------------
-- Table: pgq.tick
--
--      Snapshots for event batching
--
-- Columns:
--      tick_queue      - queue id whose tick it is
--      tick_id         - ticks id (per-queue)
--      tick_time       - time when tick happened
--      tick_snapshot
-- ----------------------------------------------------------------------
create table pgq.tick (
        tick_queue                  int4            not null,
        tick_id                     bigint          not null,
        tick_time                   timestamptz     not null default now(),
        tick_snapshot               txid_snapshot   not null default get_current_snapshot(),

	constraint tick_pkey primary key (tick_queue, tick_id),
        constraint tick_queue_fkey foreign key (tick_queue)
                                   references pgq.queue (queue_id)
);

-- ----------------------------------------------------------------------
-- Sequence: pgq.batch_id_seq
--
--      Sequence for batch id's.
-- ----------------------------------------------------------------------

create sequence pgq.batch_id_seq;
-- ----------------------------------------------------------------------
-- Table: pgq.subscription
--
--      Consumer registration on a queue
--
-- Columns:
--
--      sub_id          - subscription id for internal usage
--      sub_queue       - queue id
--      sub_consumer    - consumer's id
--      sub_tick        - last tick the consumer processed
--      sub_batch       - shortcut for queue_id/consumer_id/tick_id
--      sub_next_tick   - 
-- ----------------------------------------------------------------------
create table pgq.subscription (
	sub_id				serial      not null,
	sub_queue			int4        not null,
	sub_consumer			int4        not null,
	sub_last_tick                   bigint      not null,
        sub_active                      timestamptz not null default now(),
        sub_batch                       bigint,
        sub_next_tick                   bigint,

	constraint subscription_pkey primary key (sub_id),
        constraint sub_queue_fkey foreign key (sub_queue)
                                   references pgq.queue (queue_id),
        constraint sub_consumer_fkey foreign key (sub_consumer)
                                   references pgq.consumer (co_id)
);


-- ----------------------------------------------------------------------
-- Table: pgq.event_template
--
--      Parent table for all event tables
--
-- Columns:
--      ev_id               - event's id, supposed to be unique per queue
--      ev_time             - when the event was inserted
--      ev_txid             - transaction id which inserted the event
--      ev_owner            - subscription id that wanted to retry this
--      ev_retry            - how many times the event has been retried, NULL for new events
--      ev_type             - consumer/producer can specify what the data fields contain
--      ev_data             - data field
--      ev_extra1           - extra data field
--      ev_extra2           - extra data field
--      ev_extra3           - extra data field
--      ev_extra4           - extra data field
-- ----------------------------------------------------------------------
create table pgq.event_template (
	ev_id	            bigint          not null,
        ev_time             timestamptz     not null,

        ev_txid             bigint          not null default get_current_txid(),
        ev_owner            int4,
        ev_retry            int4,

        ev_type             text,
        ev_data             text,
        ev_extra1           text,
        ev_extra2           text,
        ev_extra3           text,
        ev_extra4           text
);

-- ----------------------------------------------------------------------
-- Table: pgq.retry_queue
--
--      Events to be retried
--
-- Columns:
--      ev_retry_after          - time when it should be re-inserted to main queue
-- ----------------------------------------------------------------------
create table pgq.retry_queue (
    ev_retry_after          timestamptz     not null,

    like pgq.event_template,

    constraint rq_pkey primary key (ev_owner, ev_id),
    constraint rq_owner_fkey foreign key (ev_owner)
                             references pgq.subscription (sub_id)
);
alter table pgq.retry_queue alter column ev_owner set not null;
alter table pgq.retry_queue alter column ev_txid drop not null;
create index rq_retry_idx on pgq.retry_queue (ev_retry_after);

-- ----------------------------------------------------------------------
-- Table: pgq.failed_queue
--
--      Events whose processing failed
--
-- Columns:
--      ev_failed_reason               - consumer's excuse for not processing
--      ev_failed_time                 - when it was tagged failed
-- ----------------------------------------------------------------------
create table pgq.failed_queue (
    ev_failed_reason                   text,
    ev_failed_time                     timestamptz not null,

    -- all event fields
    like pgq.event_template,

    constraint fq_pkey primary key (ev_owner, ev_id),
    constraint fq_owner_fkey foreign key (ev_owner)
                             references pgq.subscription (sub_id)
);
alter table pgq.failed_queue alter column ev_owner set not null;
alter table pgq.failed_queue alter column ev_txid drop not null;


