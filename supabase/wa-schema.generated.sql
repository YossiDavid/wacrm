-- ============================================================
-- wacrm schema, relocated to `wa`.
--
-- GENERATED — do not hand-edit. Regenerate with
-- scripts/generate-wa-schema.sh (see docs/wacrm-merge-plan.md §5.1).
--
-- Source: wacrm's 42 migrations (001-042) applied to a clean Postgres,
-- then dumped. The dump is the ground truth, not the migration history:
-- 017_account_sharing.sql drops and rebuilds most of what 001 created, so
-- replaying that sequence into a different schema is fragile.
--
-- NOT included here, on purpose:
--   * public.handle_new_user() and the on_auth_user_created trigger.
--     wacrm and Cortex both define them under the same names; the merged
--     version lands in the Phase 2 migration (plan §3.2).
--   * wa.accounts.business_id — the identity bridge, also Phase 2 (§3.3).
-- ============================================================

-- pg_dump emits this and it matters: functions are created before the
-- tables they query, so body validation has to stay off for this file.
set check_function_bodies = false;

create schema if not exists wa;

grant usage on schema wa to anon, authenticated, service_role;

-- pgvector backs the AI knowledge base's semantic search. Installed into
-- `extensions` rather than `public` to match Cortex's config.toml, whose
-- extra_search_path already lists it.
create extension if not exists vector with schema extensions;

-- uuid-ossp is NOT created here: Cortex's init_schema.sql already installs
-- it into public. `if not exists` would silently ignore a schema clause
-- anyway, and relocating it could break Cortex's column defaults, so this
-- schema references public.uuid_generate_v4() where it actually lives.

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.13 (Ubuntu 16.13-0ubuntu0.24.04.1)

SET check_function_bodies = false;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: account_role_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE wa.account_role_enum AS ENUM (
    'owner',
    'admin',
    'agent',
    'viewer'
);


--
-- Name: _bcast_bump(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa._bcast_bump(bid uuid, col text, delta integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $_$
BEGIN
  EXECUTE format(
    'UPDATE broadcasts SET %I = GREATEST(0, %I + $1), updated_at = NOW() WHERE id = $2',
    col, col
  ) USING delta, bid;
END;
$_$;


--
-- Name: _bcast_cols_for_status(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa._bcast_cols_for_status(s text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
  -- 'pending' contributes to nothing.
  IF s = 'pending' THEN RETURN ARRAY[]::TEXT[]; END IF;
  IF s = 'sent'      THEN RETURN ARRAY['sent_count']; END IF;
  IF s = 'delivered' THEN RETURN ARRAY['sent_count','delivered_count']; END IF;
  IF s = 'read'      THEN RETURN ARRAY['sent_count','delivered_count','read_count']; END IF;
  IF s = 'replied'   THEN RETURN ARRAY['sent_count','delivered_count','read_count','replied_count']; END IF;
  IF s = 'failed'    THEN RETURN ARRAY['failed_count']; END IF;
  RETURN ARRAY[]::TEXT[];
END;
$$;


--
-- Name: broadcast_recipient_aggregate_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.broadcast_recipient_aggregate_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  old_cols TEXT[];
  new_cols TEXT[];
  c TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    new_cols := _bcast_cols_for_status(NEW.status);
    FOREACH c IN ARRAY new_cols LOOP
      PERFORM _bcast_bump(NEW.broadcast_id, c, 1);
    END LOOP;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    old_cols := _bcast_cols_for_status(OLD.status);
    FOREACH c IN ARRAY old_cols LOOP
      PERFORM _bcast_bump(OLD.broadcast_id, c, -1);
    END LOOP;
    RETURN OLD;
  END IF;

  -- UPDATE: only care if status changed.
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    old_cols := _bcast_cols_for_status(OLD.status);
    new_cols := _bcast_cols_for_status(NEW.status);
    -- Subtract the old contributions, add the new.
    FOREACH c IN ARRAY old_cols LOOP
      PERFORM _bcast_bump(NEW.broadcast_id, c, -1);
    END LOOP;
    FOREACH c IN ARRAY new_cols LOOP
      PERFORM _bcast_bump(NEW.broadcast_id, c, 1);
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: bump_conversation_on_inbound(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.bump_conversation_on_inbound(p_conversation_id uuid, p_last_message_text text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  UPDATE conversations
  SET unread_count      = COALESCE(unread_count, 0) + 1,
      last_message_text = p_last_message_text,
      last_message_at   = NOW(),
      updated_at        = NOW()
  WHERE id = p_conversation_id;
$$;


--
-- Name: claim_ai_reply_slot(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.claim_ai_reply_slot(conversation_id uuid, max_replies integer) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  WITH claimed AS (
    UPDATE conversations
    SET ai_reply_count = ai_reply_count + 1
    WHERE id = conversation_id
      AND ai_reply_count < max_replies
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM claimed);
$$;


--
-- Name: create_broadcast_with_recipients(uuid, uuid, text, text, text, integer, uuid[], jsonb[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.create_broadcast_with_recipients(p_account_id uuid, p_user_id uuid, p_name text, p_template_name text, p_template_language text, p_total_recipients integer, p_contact_ids uuid[], p_template_params jsonb[]) RETURNS TABLE(broadcast_id uuid, recipient_id uuid, contact_id uuid)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_broadcast_id UUID;
BEGIN
  INSERT INTO broadcasts (
    account_id, user_id, name, template_name,
    template_language, status, total_recipients
  )
  VALUES (
    p_account_id, p_user_id, p_name, p_template_name,
    p_template_language, 'sending', p_total_recipients
  )
  RETURNING id INTO v_broadcast_id;

  -- Two-array unnest pairs each contact with its params positionally.
  -- A shorter params array pads with NULL, which the resume path reads
  -- as "no params" — the same as a pre-038 row.
  RETURN QUERY
  WITH ins AS (
    INSERT INTO broadcast_recipients (
      broadcast_id, contact_id, status, template_params
    )
    SELECT v_broadcast_id, t.cid, 'pending', t.prm
    FROM unnest(p_contact_ids, p_template_params) AS t(cid, prm)
    -- Qualified: a bare `contact_id` collides with the RETURNS TABLE
    -- output variable of the same name. This is the whole fix.
    RETURNING id, broadcast_recipients.contact_id
  )
  SELECT v_broadcast_id, ins.id, ins.contact_id
  FROM ins;
END;
$$;


--
-- Name: enforce_profile_privilege_columns(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.enforce_profile_privilege_columns() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
BEGIN
  IF (NEW.account_role IS DISTINCT FROM OLD.account_role
      OR NEW.account_id IS DISTINCT FROM OLD.account_id)
     AND current_user = 'authenticated'
  THEN
    RAISE EXCEPTION
      'account_role and account_id cannot be changed directly; use the account member/invitation RPCs'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.contacts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    phone text NOT NULL,
    name text,
    email text,
    company text,
    avatar_url text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL,
    phone_normalized text GENERATED ALWAYS AS (regexp_replace(phone, '\D'::text, ''::text, 'g'::text)) STORED,
    wa_user_id text,
    wa_parent_user_id text,
    wa_username text
);


--
-- Name: COLUMN contacts.wa_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.contacts.wa_user_id IS 'WhatsApp business-scoped user ID (e.g. "US.13491208655302741918"). Stable per (user, business portfolio) and the primary inbound key when Meta withholds the phone number.';


--
-- Name: COLUMN contacts.wa_parent_user_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.contacts.wa_parent_user_id IS 'Portfolio-level BSUID (e.g. "US.ENT.11815799212886844830"). Stored for reference; not used as a lookup key.';


--
-- Name: COLUMN contacts.wa_username; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.contacts.wa_username IS 'WhatsApp username, without the leading @. Display only — usernames are user-changeable and must never be used as an identity key.';


--
-- Name: filter_contacts_by_tags(uuid[], text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.filter_contacts_by_tags(p_tag_ids uuid[], p_search text DEFAULT NULL::text, p_limit integer DEFAULT 25, p_offset integer DEFAULT 0) RETURNS TABLE(contact wa.contacts, total_count bigint)
    LANGUAGE sql STABLE
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  WITH matched AS (
    -- Distinct contacts having ANY of the selected tags (OR),
    -- narrowed by the same name/phone/email search as the list.
    SELECT DISTINCT c.id, c.created_at
    FROM contacts c
    JOIN contact_tags ct ON ct.contact_id = c.id
    WHERE ct.tag_id = ANY(p_tag_ids)
      AND (
        p_search IS NULL
        OR c.name ILIKE '%' || p_search || '%'
        OR c.phone ILIKE '%' || p_search || '%'
        OR c.email ILIKE '%' || p_search || '%'
      )
  ),
  page AS (
    -- count(*) OVER() is evaluated before LIMIT, so it is the full
    -- match total regardless of the page being returned.
    SELECT id, count(*) OVER() AS total_count
    FROM matched
    ORDER BY created_at DESC, id
    LIMIT p_limit OFFSET p_offset
  )
  SELECT c AS contact, page.total_count
  FROM page
  JOIN contacts c ON c.id = page.id
  ORDER BY c.created_at DESC, c.id;
$$;


--
-- Name: increment_automation_execution_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.increment_automation_execution_count(p_automation_id uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  UPDATE automations
  SET
    execution_count = execution_count + 1,
    last_executed_at = NOW()
  WHERE id = p_automation_id;
$$;


--
-- Name: increment_flow_execution_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.increment_flow_execution_count(p_flow_id uuid) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  UPDATE flows
  SET
    execution_count = execution_count + 1,
    last_executed_at = NOW()
  WHERE id = p_flow_id;
$$;


--
-- Name: is_account_member(uuid, wa.account_role_enum); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.is_account_member(target_account_id uuid, min_role wa.account_role_enum DEFAULT 'viewer'::wa.account_role_enum) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM profiles p
    WHERE p.user_id = auth.uid()
      AND p.account_id = target_account_id
      AND CASE p.account_role
            WHEN 'owner'  THEN 4
            WHEN 'admin'  THEN 3
            WHEN 'agent'  THEN 2
            WHEN 'viewer' THEN 1
          END
        >=
          CASE min_role
            WHEN 'owner'  THEN 4
            WHEN 'admin'  THEN 3
            WHEN 'agent'  THEN 2
            WHEN 'viewer' THEN 1
          END
  );
$$;


--
-- Name: match_ai_knowledge_fts(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.match_ai_knowledge_fts(p_account_id uuid, p_query text, p_match_count integer) RETURNS TABLE(id uuid, content text, rank real)
    LANGUAGE sql STABLE
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  SELECT c.id,
         c.content,
         ts_rank(c.fts, plainto_tsquery('simple', p_query)) AS rank
  FROM ai_knowledge_chunks c
  WHERE c.account_id = p_account_id
    AND c.fts @@ plainto_tsquery('simple', p_query)
  ORDER BY rank DESC
  LIMIT GREATEST(p_match_count, 0);
$$;


--
-- Name: match_ai_knowledge_semantic(uuid, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.match_ai_knowledge_semantic(p_account_id uuid, p_query_embedding text, p_match_count integer) RETURNS TABLE(id uuid, content text, distance real)
    LANGUAGE sql STABLE
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  SELECT c.id,
         c.content,
         (c.embedding <=> p_query_embedding::vector(1536)) AS distance
  FROM ai_knowledge_chunks c
  WHERE c.account_id = p_account_id
    AND c.embedding IS NOT NULL
  ORDER BY c.embedding <=> p_query_embedding::vector(1536)
  LIMIT GREATEST(p_match_count, 0);
$$;


--
-- Name: merge_duplicate_contacts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.merge_duplicate_contacts() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_group   RECORD;
  v_survivor UUID;
  v_losers   UUID[];
  v_merged   INTEGER := 0;
BEGIN
  FOR v_group IN
    SELECT account_id,
           phone_normalized,
           array_agg(id ORDER BY created_at ASC, id ASC) AS ids
    FROM contacts
    WHERE phone_normalized <> ''
    GROUP BY account_id, phone_normalized
    HAVING count(*) > 1
  LOOP
    v_survivor := v_group.ids[1];
    v_losers   := v_group.ids[2:array_length(v_group.ids, 1)];

    -- Plain re-point: these tables have no contact-scoped unique
    -- constraint. `conversations` is ON DELETE CASCADE, so this
    -- re-point is what saves its rows (and their messages) from
    -- being deleted with the loser contact.
    UPDATE conversations                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE contact_notes                 SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE deals                         SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE broadcast_recipients          SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_logs               SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);
    UPDATE automation_pending_executions SET contact_id = v_survivor WHERE contact_id = ANY(v_losers);

    -- Conflict-guarded re-point for UNIQUE(contact_id, tag_id):
    -- move only tags the survivor doesn't already have, drop the rest.
    UPDATE contact_tags ct SET contact_id = v_survivor
      WHERE ct.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_tags s
          WHERE s.contact_id = v_survivor AND s.tag_id = ct.tag_id
        );
    DELETE FROM contact_tags WHERE contact_id = ANY(v_losers);

    -- Same guard for UNIQUE(contact_id, custom_field_id). Survivor's
    -- own value wins on conflict.
    UPDATE contact_custom_values cv SET contact_id = v_survivor
      WHERE cv.contact_id = ANY(v_losers)
        AND NOT EXISTS (
          SELECT 1 FROM contact_custom_values s
          WHERE s.contact_id = v_survivor AND s.custom_field_id = cv.custom_field_id
        );
    DELETE FROM contact_custom_values WHERE contact_id = ANY(v_losers);

    -- flow_runs has a partial UNIQUE on active runs per contact.
    -- Re-point only NON-active runs (exempt from the partial index)
    -- to preserve history; any active loser run is left to be
    -- NULLed by its FK's ON DELETE SET NULL when the loser is
    -- removed below — avoids colliding with the survivor's active run.
    UPDATE flow_runs SET contact_id = v_survivor
      WHERE contact_id = ANY(v_losers) AND status <> 'active';

    DELETE FROM contacts WHERE id = ANY(v_losers);

    v_merged := v_merged + COALESCE(array_length(v_losers, 1), 0);
  END LOOP;

  RETURN v_merged;
END;
$$;


--
-- Name: merge_duplicate_conversations(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.merge_duplicate_conversations() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_group    RECORD;
  v_survivor UUID;
  v_losers   UUID[];
  v_all      UUID[];
  v_merged   INTEGER := 0;
BEGIN
  FOR v_group IN
    SELECT account_id,
           contact_id,
           array_agg(id ORDER BY created_at ASC, id ASC) AS ids,
           COALESCE(SUM(unread_count), 0)                AS total_unread
    FROM conversations
    GROUP BY account_id, contact_id
    HAVING count(*) > 1
  LOOP
    v_all      := v_group.ids;
    v_survivor := v_all[1];
    v_losers   := v_all[2:array_length(v_all, 1)];

    -- Re-point every conversation-scoped child from the losers onto
    -- the survivor. None of these carry a conversation-scoped unique
    -- constraint (message_id is intentionally non-unique — see
    -- migration 009), so a plain UPDATE is safe. Doing this BEFORE the
    -- delete is what saves the ON DELETE CASCADE children (messages,
    -- message_reactions, notifications) from being removed with the
    -- loser conversations.
    UPDATE messages          SET conversation_id = v_survivor WHERE conversation_id = ANY(v_losers);
    UPDATE message_reactions SET conversation_id = v_survivor WHERE conversation_id = ANY(v_losers);
    UPDATE deals             SET conversation_id = v_survivor WHERE conversation_id = ANY(v_losers);
    UPDATE flow_runs         SET conversation_id = v_survivor WHERE conversation_id = ANY(v_losers);
    UPDATE notifications     SET conversation_id = v_survivor WHERE conversation_id = ANY(v_losers);
    UPDATE ai_usage_log      SET conversation_id = v_survivor WHERE conversation_id = ANY(v_losers);

    -- Roll the merged unread counts onto the survivor and re-derive
    -- its last-message summary from the now-complete message set, so
    -- the surviving thread reflects the full history.
    UPDATE conversations c
    SET unread_count      = v_group.total_unread,
        last_message_text = lm.content_text,
        last_message_at   = lm.created_at,
        updated_at        = NOW()
    FROM (
      SELECT content_text, created_at
      FROM messages
      WHERE conversation_id = v_survivor
      ORDER BY created_at DESC
      LIMIT 1
    ) lm
    WHERE c.id = v_survivor;

    -- Survivor may have no messages at all (edge case). Still fold in
    -- the merged unread count in that case.
    UPDATE conversations
    SET unread_count = v_group.total_unread,
        updated_at   = NOW()
    WHERE id = v_survivor
      AND NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id = v_survivor);

    DELETE FROM conversations WHERE id = ANY(v_losers);

    v_merged := v_merged + COALESCE(array_length(v_losers, 1), 0);
  END LOOP;

  RETURN v_merged;
END;
$$;


--
-- Name: notify_conversation_assigned(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.notify_conversation_assigned() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_contact_name TEXT;
  v_actor_name TEXT;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.assigned_agent_id IS NULL THEN
      RETURN NEW;
    END IF;
  ELSE
    IF NEW.assigned_agent_id IS NULL
       OR NEW.assigned_agent_id IS NOT DISTINCT FROM OLD.assigned_agent_id THEN
      RETURN NEW;
    END IF;
  END IF;

  -- Skip self-assignment — nothing to notify the agent about.
  IF auth.uid() IS NOT NULL AND auth.uid() = NEW.assigned_agent_id THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(NULLIF(name, ''), phone) INTO v_contact_name
  FROM contacts WHERE id = NEW.contact_id;

  IF auth.uid() IS NOT NULL THEN
    SELECT full_name INTO v_actor_name
    FROM profiles WHERE user_id = auth.uid();
  END IF;

  INSERT INTO notifications (
    account_id, user_id, type, conversation_id, contact_id,
    actor_user_id, title, body
  ) VALUES (
    NEW.account_id,
    NEW.assigned_agent_id,
    'conversation_assigned',
    NEW.id,
    NEW.contact_id,
    auth.uid(),
    'New conversation assigned',
    COALESCE(v_actor_name, 'Someone') || ' assigned you a conversation with '
      || COALESCE(v_contact_name, 'a contact')
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never let a notification failure block the assignment itself.
  RAISE WARNING 'Failed to create assignment notification for conversation %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;


--
-- Name: peek_invitation(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.peek_invitation(p_token_hash text) RETURNS json
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_inv account_invitations%ROWTYPE;
  v_account_name TEXT;
BEGIN
  SELECT * INTO v_inv
  FROM account_invitations
  WHERE token_hash = p_token_hash;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inv.accepted_at IS NOT NULL THEN
    RETURN json_build_object('ok', false, 'reason', 'used');
  END IF;

  IF v_inv.expires_at <= NOW() THEN
    RETURN json_build_object('ok', false, 'reason', 'expired');
  END IF;

  SELECT name INTO v_account_name
  FROM accounts
  WHERE id = v_inv.account_id;

  RETURN json_build_object(
    'ok', true,
    'account_name', v_account_name,
    'role', v_inv.role,
    'expires_at', v_inv.expires_at
  );
END;
$$;


--
-- Name: recompute_broadcast_counts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.recompute_broadcast_counts(bid uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
BEGIN
  UPDATE broadcasts b SET
    sent_count      = agg.sent_count,
    delivered_count = agg.delivered_count,
    read_count      = agg.read_count,
    replied_count   = agg.replied_count,
    failed_count    = agg.failed_count,
    updated_at      = NOW()
  FROM (
    SELECT
      COUNT(*) FILTER (WHERE status IN ('sent','delivered','read','replied')) AS sent_count,
      COUNT(*) FILTER (WHERE status IN ('delivered','read','replied'))        AS delivered_count,
      COUNT(*) FILTER (WHERE status IN ('read','replied'))                    AS read_count,
      COUNT(*) FILTER (WHERE status = 'replied')                              AS replied_count,
      COUNT(*) FILTER (WHERE status = 'failed')                               AS failed_count
    FROM broadcast_recipients
    WHERE broadcast_id = bid
  ) agg
  WHERE b.id = bid;
END;
$$;


--
-- Name: record_webhook_failure(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.record_webhook_failure(endpoint_id uuid, max_failures integer) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
  UPDATE webhook_endpoints
  SET failure_count = failure_count + 1,
      is_active = CASE
        WHEN failure_count + 1 >= max_failures THEN false
        ELSE is_active
      END
  WHERE id = endpoint_id;
$$;


--
-- Name: redeem_invitation(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.redeem_invitation(p_token_hash text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_inv account_invitations%ROWTYPE;
  v_old_account_id UUID;
  v_old_account_owner UUID;
  v_has_data BOOLEAN;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_inv
  FROM account_invitations
  WHERE token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invitation not found' USING ERRCODE = '22023';
  END IF;
  IF v_inv.accepted_at IS NOT NULL THEN
    RAISE EXCEPTION 'Invitation has already been redeemed'
      USING ERRCODE = '22023';
  END IF;
  IF v_inv.expires_at <= NOW() THEN
    RAISE EXCEPTION 'Invitation has expired' USING ERRCODE = '22023';
  END IF;

  -- Caller's current account + its owner.
  SELECT p.account_id, a.owner_user_id
  INTO v_old_account_id, v_old_account_owner
  FROM profiles p
  JOIN accounts a ON a.id = p.account_id
  WHERE p.user_id = v_caller_id;

  IF v_old_account_id IS NULL THEN
    -- Defensive — every authenticated user has a profile post-017.
    RAISE EXCEPTION 'Caller has no profile' USING ERRCODE = '42501';
  END IF;

  -- Edge case: the inviter sent themselves a link, or the
  -- caller is somehow already in the inviter's account.
  IF v_old_account_id = v_inv.account_id THEN
    RAISE EXCEPTION 'You are already a member of this account'
      USING ERRCODE = '23505';
  END IF;

  -- Safety: the caller must be the SOLE OWNER of their current
  -- account (i.e. their fresh personal account from signup or a
  -- prior removal). Any other state means they're either:
  --   - a member of another shared account (joining a second
  --     would silently orphan their access to the first), or
  --   - the owner of an account with teammates (they'd abandon
  --     their team to join the inviter's).
  -- Either way, the safe answer is "make a different login".
  IF v_old_account_owner <> v_caller_id THEN
    RAISE EXCEPTION 'You are already in a shared account; sign up with a different email to join this one'
      USING ERRCODE = '23505';
  END IF;

  -- Belt: even if they own their account, refuse if it has any
  -- domain data — joining would orphan their contacts, deals,
  -- broadcasts, automations, flows, templates, etc.
  SELECT EXISTS (
    SELECT 1 FROM contacts WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM conversations WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM broadcasts WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM automations WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM flows WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM pipelines WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM message_templates WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM tags WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM custom_fields WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM contact_notes WHERE account_id = v_old_account_id
    UNION ALL SELECT 1 FROM whatsapp_config WHERE account_id = v_old_account_id
    LIMIT 1
  ) INTO v_has_data;

  IF v_has_data THEN
    RAISE EXCEPTION 'Your account already contains data; sign up with a different email to join this one'
      USING ERRCODE = '23505';
  END IF;

  -- Move the profile first so the cascade-on-delete of the old
  -- account doesn't try to nuke this user's profile too.
  UPDATE profiles
  SET account_id = v_inv.account_id,
      account_role = v_inv.role
  WHERE user_id = v_caller_id;

  UPDATE account_invitations
  SET accepted_at = NOW(),
      accepted_by_user_id = v_caller_id
  WHERE id = v_inv.id;

  -- Clean up the orphan personal account. Empty by the checks
  -- above, so this is purely housekeeping — no cascades fire
  -- because no other rows reference it.
  DELETE FROM accounts WHERE id = v_old_account_id;

  RETURN v_inv.account_id;
END;
$$;


--
-- Name: remove_account_member(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.remove_account_member(p_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_caller_account_id UUID;
  v_caller_role account_role_enum;
  v_target_account_id UUID;
  v_target_role account_role_enum;
  v_target_name TEXT;
  v_target_email TEXT;
  v_new_account_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT account_id, account_role
  INTO v_caller_account_id, v_caller_role
  FROM profiles
  WHERE user_id = auth.uid();

  IF v_caller_account_id IS NULL THEN
    RAISE EXCEPTION 'Caller has no account' USING ERRCODE = '42501';
  END IF;

  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'This action requires the admin role or higher'
      USING ERRCODE = '42501';
  END IF;

  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot remove yourself; transfer ownership or leave the account instead'
      USING ERRCODE = '22023';
  END IF;

  SELECT account_id, account_role, full_name, email
  INTO v_target_account_id, v_target_role, v_target_name, v_target_email
  FROM profiles
  WHERE user_id = p_user_id;

  IF v_target_account_id IS NULL THEN
    RAISE EXCEPTION 'Target user not found' USING ERRCODE = '22023';
  END IF;

  IF v_target_account_id <> v_caller_account_id THEN
    RAISE EXCEPTION 'Target user is not a member of your account'
      USING ERRCODE = '42501';
  END IF;

  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Cannot remove the account owner; transfer ownership first'
      USING ERRCODE = '22023';
  END IF;

  -- Spin up a fresh personal account for the removed user. Mirror
  -- of handle_new_user's logic — keep them whole, just relocated.
  INSERT INTO accounts (name, owner_user_id)
  VALUES (
    COALESCE(NULLIF(v_target_name, ''), v_target_email, 'My account'),
    p_user_id
  )
  RETURNING id INTO v_new_account_id;

  UPDATE profiles
  SET account_id = v_new_account_id,
      account_role = 'owner'
  WHERE user_id = p_user_id;

  RETURN v_new_account_id;
END;
$$;


--
-- Name: set_member_role(uuid, wa.account_role_enum); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.set_member_role(p_user_id uuid, p_new_role wa.account_role_enum) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_caller_account_id UUID;
  v_caller_role account_role_enum;
  v_target_account_id UUID;
  v_target_role account_role_enum;
BEGIN
  -- Caller must be authenticated.
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  -- Resolve caller's account + role.
  SELECT account_id, account_role
  INTO v_caller_account_id, v_caller_role
  FROM profiles
  WHERE user_id = auth.uid();

  IF v_caller_account_id IS NULL THEN
    RAISE EXCEPTION 'Caller has no account' USING ERRCODE = '42501';
  END IF;

  -- Caller must be admin+.
  IF v_caller_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION 'This action requires the admin role or higher'
      USING ERRCODE = '42501';
  END IF;

  -- Can't change own role via this endpoint.
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot change your own role'
      USING ERRCODE = '22023';
  END IF;

  -- Resolve target.
  SELECT account_id, account_role
  INTO v_target_account_id, v_target_role
  FROM profiles
  WHERE user_id = p_user_id;

  IF v_target_account_id IS NULL THEN
    RAISE EXCEPTION 'Target user not found' USING ERRCODE = '22023';
  END IF;

  -- Target must be in caller's account.
  IF v_target_account_id <> v_caller_account_id THEN
    RAISE EXCEPTION 'Target user is not a member of your account'
      USING ERRCODE = '42501';
  END IF;

  -- Owner role changes go through transfer_account_ownership.
  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Use transfer_account_ownership to demote an owner'
      USING ERRCODE = '22023';
  END IF;
  IF p_new_role = 'owner' THEN
    RAISE EXCEPTION 'Use transfer_account_ownership to promote to owner'
      USING ERRCODE = '22023';
  END IF;

  UPDATE profiles
  SET account_role = p_new_role
  WHERE user_id = p_user_id;
END;
$$;


--
-- Name: touch_presence(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.touch_presence(p_status text DEFAULT 'online'::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_account_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  IF p_status NOT IN ('online', 'away') THEN
    RAISE EXCEPTION 'Invalid presence status: %', p_status
      USING ERRCODE = '22023';
  END IF;

  SELECT account_id INTO v_account_id
  FROM profiles
  WHERE user_id = auth.uid();

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'No account for caller' USING ERRCODE = '22023';
  END IF;

  INSERT INTO member_presence (user_id, account_id, status, last_seen_at)
  VALUES (auth.uid(), v_account_id, p_status, now())
  ON CONFLICT (user_id) DO UPDATE
    SET status       = excluded.status,
        last_seen_at = now(),
        account_id   = excluded.account_id;
END;
$$;


--
-- Name: transfer_account_ownership(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.transfer_account_ownership(p_new_owner_user_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'wa', 'public', 'extensions'
    AS $$
DECLARE
  v_caller_account_id UUID;
  v_caller_role account_role_enum;
  v_target_account_id UUID;
  v_target_role account_role_enum;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT account_id, account_role
  INTO v_caller_account_id, v_caller_role
  FROM profiles
  WHERE user_id = auth.uid();

  IF v_caller_account_id IS NULL THEN
    RAISE EXCEPTION 'Caller has no account' USING ERRCODE = '42501';
  END IF;

  IF v_caller_role <> 'owner' THEN
    RAISE EXCEPTION 'Only the account owner can transfer ownership'
      USING ERRCODE = '42501';
  END IF;

  IF p_new_owner_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You are already the owner'
      USING ERRCODE = '22023';
  END IF;

  SELECT account_id, account_role
  INTO v_target_account_id, v_target_role
  FROM profiles
  WHERE user_id = p_new_owner_user_id;

  IF v_target_account_id IS NULL THEN
    RAISE EXCEPTION 'Target user not found' USING ERRCODE = '22023';
  END IF;

  IF v_target_account_id <> v_caller_account_id THEN
    RAISE EXCEPTION 'Target user is not a member of your account'
      USING ERRCODE = '42501';
  END IF;

  -- Demote current owner first so the temporary state where the
  -- account has zero owners is never visible — both writes happen
  -- in the same function transaction.
  UPDATE profiles SET account_role = 'admin'
  WHERE user_id = auth.uid();

  UPDATE profiles SET account_role = 'owner'
  WHERE user_id = p_new_owner_user_id;

  UPDATE accounts SET owner_user_id = p_new_owner_user_id
  WHERE id = v_caller_account_id;
END;
$$;


--
-- Name: update_ai_configs_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.update_ai_configs_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: update_ai_knowledge_documents_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.update_ai_knowledge_documents_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION wa.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: account_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.account_invitations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    account_id uuid NOT NULL,
    token_hash text NOT NULL,
    role wa.account_role_enum NOT NULL,
    created_by_user_id uuid,
    label text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    accepted_at timestamp with time zone,
    accepted_by_user_id uuid,
    CONSTRAINT account_invitations_role_check CHECK ((role <> 'owner'::wa.account_role_enum))
);


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.accounts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    owner_user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    default_currency text DEFAULT 'USD'::text NOT NULL,
    CONSTRAINT accounts_default_currency_format CHECK ((default_currency ~ '^[A-Z]{3}$'::text))
);


--
-- Name: ai_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.ai_configs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    created_by uuid,
    provider text NOT NULL,
    model text NOT NULL,
    api_key text NOT NULL,
    system_prompt text,
    is_active boolean DEFAULT false NOT NULL,
    auto_reply_enabled boolean DEFAULT false NOT NULL,
    auto_reply_max_per_conversation integer DEFAULT 3 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    embeddings_api_key text,
    handoff_agent_id uuid,
    CONSTRAINT ai_configs_auto_reply_max_per_conversation_check CHECK (((auto_reply_max_per_conversation >= 1) AND (auto_reply_max_per_conversation <= 20))),
    CONSTRAINT ai_configs_provider_check CHECK ((provider = ANY (ARRAY['openai'::text, 'anthropic'::text])))
);


--
-- Name: ai_knowledge_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.ai_knowledge_chunks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    document_id uuid NOT NULL,
    account_id uuid NOT NULL,
    chunk_index integer DEFAULT 0 NOT NULL,
    content text NOT NULL,
    fts tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, content)) STORED,
    embedding extensions.vector(1536),
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_knowledge_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.ai_knowledge_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    created_by uuid,
    title text NOT NULL,
    content text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_usage_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.ai_usage_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    conversation_id uuid,
    mode text NOT NULL,
    provider text NOT NULL,
    model text NOT NULL,
    prompt_tokens integer DEFAULT 0 NOT NULL,
    completion_tokens integer DEFAULT 0 NOT NULL,
    total_tokens integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ai_usage_log_mode_check CHECK ((mode = ANY (ARRAY['auto_reply'::text, 'draft'::text]))),
    CONSTRAINT ai_usage_log_provider_check CHECK ((provider = ANY (ARRAY['openai'::text, 'anthropic'::text])))
);


--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.api_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    created_by uuid,
    name text NOT NULL,
    key_prefix text NOT NULL,
    key_hash text NOT NULL,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    last_used_at timestamp with time zone,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: automation_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.automation_logs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    automation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    contact_id uuid,
    trigger_event text NOT NULL,
    steps_executed jsonb DEFAULT '[]'::jsonb NOT NULL,
    status text NOT NULL,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    account_id uuid NOT NULL,
    CONSTRAINT automation_logs_status_check CHECK ((status = ANY (ARRAY['success'::text, 'partial'::text, 'failed'::text])))
);


--
-- Name: automation_pending_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.automation_pending_executions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    automation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    contact_id uuid,
    log_id uuid,
    parent_step_id uuid,
    branch text,
    next_step_position integer NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    run_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    account_id uuid NOT NULL,
    CONSTRAINT automation_pending_executions_branch_check CHECK ((branch = ANY (ARRAY['yes'::text, 'no'::text]))),
    CONSTRAINT automation_pending_executions_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'done'::text, 'failed'::text])))
);


--
-- Name: automation_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.automation_steps (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    automation_id uuid NOT NULL,
    parent_step_id uuid,
    branch text,
    step_type text NOT NULL,
    step_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    "position" integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT automation_steps_branch_check CHECK ((branch = ANY (ARRAY['yes'::text, 'no'::text])))
);


--
-- Name: automations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.automations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    trigger_type text NOT NULL,
    trigger_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_active boolean DEFAULT false NOT NULL,
    execution_count integer DEFAULT 0 NOT NULL,
    last_executed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    account_id uuid NOT NULL
);


--
-- Name: broadcast_recipients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.broadcast_recipients (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    broadcast_id uuid NOT NULL,
    contact_id uuid,
    status text DEFAULT 'pending'::text NOT NULL,
    sent_at timestamp with time zone,
    delivered_at timestamp with time zone,
    read_at timestamp with time zone,
    replied_at timestamp with time zone,
    error_message text,
    created_at timestamp with time zone DEFAULT now(),
    whatsapp_message_id text,
    template_params jsonb,
    CONSTRAINT broadcast_recipients_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'delivered'::text, 'read'::text, 'replied'::text, 'failed'::text])))
);


--
-- Name: COLUMN broadcast_recipients.template_params; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.broadcast_recipients.template_params IS 'Positional body values for this recipient''s template send ({{1}}, {{2}}, ...), frozen when the broadcast was planned. NULL on rows created before migration 038; a resume treats that as no params.';


--
-- Name: broadcasts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.broadcasts (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    template_name text NOT NULL,
    template_language text DEFAULT 'en_US'::text NOT NULL,
    template_variables jsonb,
    audience_filter jsonb,
    scheduled_at timestamp with time zone,
    status text DEFAULT 'draft'::text NOT NULL,
    total_recipients integer DEFAULT 0,
    sent_count integer DEFAULT 0,
    delivered_count integer DEFAULT 0,
    read_count integer DEFAULT 0,
    replied_count integer DEFAULT 0,
    failed_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL,
    delivery_locked_at timestamp with time zone,
    CONSTRAINT broadcasts_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'sending'::text, 'sent'::text, 'failed'::text])))
);


--
-- Name: COLUMN broadcasts.delivery_locked_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.broadcasts.delivery_locked_at IS 'Set while a server-side delivery pass is fanning out; NULL when idle. See 038_broadcast_resume.sql.';


--
-- Name: contact_custom_values; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.contact_custom_values (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    contact_id uuid NOT NULL,
    custom_field_id uuid NOT NULL,
    value text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: contact_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.contact_notes (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    contact_id uuid NOT NULL,
    user_id uuid NOT NULL,
    note_text text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL
);


--
-- Name: contact_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.contact_tags (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    contact_id uuid NOT NULL,
    tag_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.conversations (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    contact_id uuid NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    assigned_agent_id uuid,
    last_message_text text,
    last_message_at timestamp with time zone,
    unread_count integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL,
    ai_autoreply_disabled boolean DEFAULT false NOT NULL,
    ai_reply_count integer DEFAULT 0 NOT NULL,
    ai_handoff_summary text,
    CONSTRAINT conversations_status_check CHECK ((status = ANY (ARRAY['open'::text, 'pending'::text, 'closed'::text])))
);


--
-- Name: custom_fields; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.custom_fields (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    field_name text NOT NULL,
    field_type text DEFAULT 'text'::text NOT NULL,
    field_options jsonb,
    created_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL
);


--
-- Name: deals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.deals (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    pipeline_id uuid NOT NULL,
    stage_id uuid NOT NULL,
    contact_id uuid,
    conversation_id uuid,
    title text NOT NULL,
    value numeric(12,2) DEFAULT 0 NOT NULL,
    currency text DEFAULT 'USD'::text,
    notes text,
    expected_close_date date,
    status text DEFAULT 'open'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    assigned_to uuid,
    account_id uuid NOT NULL,
    CONSTRAINT deals_status_check CHECK ((status = ANY (ARRAY['open'::text, 'won'::text, 'lost'::text])))
);


--
-- Name: flow_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.flow_nodes (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    flow_id uuid NOT NULL,
    node_key text NOT NULL,
    node_type text NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    position_x integer DEFAULT 0 NOT NULL,
    position_y integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT flow_nodes_node_type_check CHECK ((node_type = ANY (ARRAY['start'::text, 'send_buttons'::text, 'send_list'::text, 'send_message'::text, 'send_media'::text, 'collect_input'::text, 'condition'::text, 'set_tag'::text, 'handoff'::text, 'http_fetch'::text, 'end'::text])))
);


--
-- Name: flow_run_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.flow_run_events (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    flow_run_id uuid NOT NULL,
    event_type text NOT NULL,
    node_key text,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT flow_run_events_event_type_check CHECK ((event_type = ANY (ARRAY['started'::text, 'node_entered'::text, 'message_sent'::text, 'reply_received'::text, 'fallback_fired'::text, 'handoff'::text, 'timeout'::text, 'error'::text, 'completed'::text])))
);


--
-- Name: flow_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.flow_runs (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    flow_id uuid NOT NULL,
    user_id uuid NOT NULL,
    contact_id uuid,
    conversation_id uuid,
    status text DEFAULT 'active'::text NOT NULL,
    current_node_key text,
    last_prompt_message_id uuid,
    vars jsonb DEFAULT '{}'::jsonb NOT NULL,
    reprompt_count integer DEFAULT 0 NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    last_advanced_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    end_reason text,
    account_id uuid NOT NULL,
    CONSTRAINT flow_runs_status_check CHECK ((status = ANY (ARRAY['active'::text, 'completed'::text, 'handed_off'::text, 'timed_out'::text, 'paused_by_agent'::text, 'failed'::text])))
);


--
-- Name: flows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.flows (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    description text,
    status text DEFAULT 'draft'::text NOT NULL,
    trigger_type text NOT NULL,
    trigger_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    entry_node_id text,
    fallback_policy jsonb DEFAULT '{"on_exhaust": "handoff", "max_reprompts": 2, "on_timeout_hours": 24, "on_unknown_reply": "reprompt"}'::jsonb NOT NULL,
    execution_count integer DEFAULT 0 NOT NULL,
    last_executed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    account_id uuid NOT NULL,
    CONSTRAINT flows_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'archived'::text]))),
    CONSTRAINT flows_trigger_type_check CHECK ((trigger_type = ANY (ARRAY['keyword'::text, 'first_inbound_message'::text, 'manual'::text])))
);


--
-- Name: member_presence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.member_presence (
    user_id uuid NOT NULL,
    account_id uuid NOT NULL,
    status text DEFAULT 'online'::text NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT member_presence_status_check CHECK ((status = ANY (ARRAY['online'::text, 'away'::text])))
);


--
-- Name: message_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.message_reactions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    message_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    actor_type text NOT NULL,
    actor_id uuid,
    emoji text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT message_reactions_actor_type_check CHECK ((actor_type = ANY (ARRAY['customer'::text, 'agent'::text])))
);


--
-- Name: message_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.message_templates (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    category text DEFAULT 'Marketing'::text NOT NULL,
    language text DEFAULT 'en_US'::text,
    header_type text,
    header_content text,
    body_text text NOT NULL,
    footer_text text,
    buttons jsonb,
    status text DEFAULT 'DRAFT'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    sample_values jsonb,
    meta_template_id text,
    rejection_reason text,
    quality_score text,
    header_handle text,
    header_media_url text,
    submission_error text,
    last_submitted_at timestamp with time zone,
    account_id uuid NOT NULL,
    CONSTRAINT message_templates_buttons_shape_check CHECK (((buttons IS NULL) OR ((jsonb_typeof(buttons) = 'array'::text) AND (jsonb_array_length(buttons) <= 10)))),
    CONSTRAINT message_templates_category_check CHECK ((category = ANY (ARRAY['Marketing'::text, 'Utility'::text, 'Authentication'::text]))),
    CONSTRAINT message_templates_header_type_check CHECK ((header_type = ANY (ARRAY['text'::text, 'image'::text, 'video'::text, 'document'::text]))),
    CONSTRAINT message_templates_quality_score_check CHECK (((quality_score IS NULL) OR (quality_score = ANY (ARRAY['GREEN'::text, 'YELLOW'::text, 'RED'::text])))),
    CONSTRAINT message_templates_status_meta_check CHECK ((status = ANY (ARRAY['DRAFT'::text, 'PENDING'::text, 'APPROVED'::text, 'REJECTED'::text, 'PAUSED'::text, 'DISABLED'::text, 'IN_APPEAL'::text, 'PENDING_DELETION'::text])))
);


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.messages (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    conversation_id uuid NOT NULL,
    sender_type text NOT NULL,
    sender_id uuid,
    content_type text DEFAULT 'text'::text NOT NULL,
    content_text text,
    media_url text,
    template_name text,
    message_id text,
    status text DEFAULT 'sent'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    reply_to_message_id uuid,
    interactive_reply_id text,
    ai_generated boolean DEFAULT false NOT NULL,
    interactive_payload jsonb,
    media_type text,
    error_code integer,
    error_title text,
    error_details text,
    CONSTRAINT messages_content_type_check CHECK ((content_type = ANY (ARRAY['text'::text, 'image'::text, 'document'::text, 'audio'::text, 'video'::text, 'location'::text, 'template'::text, 'interactive'::text]))),
    CONSTRAINT messages_sender_type_check CHECK ((sender_type = ANY (ARRAY['customer'::text, 'agent'::text, 'bot'::text]))),
    CONSTRAINT messages_status_check CHECK ((status = ANY (ARRAY['sending'::text, 'sent'::text, 'delivered'::text, 'read'::text, 'failed'::text])))
);


--
-- Name: COLUMN messages.media_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.messages.media_type IS 'MIME type of media_url''s content, as reported by Meta. Populated for INBOUND media only: an outbound media_url is a chat-media object whose path already carries the original filename and extension, so the type adds nothing there. Also NULL for text messages and for every row written before migration 039.';


--
-- Name: COLUMN messages.error_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.messages.error_code IS 'Meta''s numeric error code from a failed status webhook (errors[0].code). NULL unless the message failed. Not cleared by a later status update.';


--
-- Name: COLUMN messages.error_title; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.messages.error_title IS 'Meta''s short error label from a failed status webhook (errors[0].title). NULL unless the message failed.';


--
-- Name: COLUMN messages.error_details; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.messages.error_details IS 'Meta''s human-readable explanation from a failed status webhook (errors[0].error_data.details). NULL unless the message failed and Meta supplied details.';


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.notifications (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    account_id uuid NOT NULL,
    user_id uuid NOT NULL,
    type text DEFAULT 'conversation_assigned'::text NOT NULL,
    conversation_id uuid,
    contact_id uuid,
    actor_user_id uuid,
    title text NOT NULL,
    body text,
    read_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT notifications_type_check CHECK ((type = 'conversation_assigned'::text))
);

ALTER TABLE ONLY wa.notifications REPLICA IDENTITY FULL;


--
-- Name: pipeline_stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.pipeline_stages (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    pipeline_id uuid NOT NULL,
    name text NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    color text DEFAULT '#3b82f6'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: pipelines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.pipelines (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.profiles (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    full_name text NOT NULL,
    email text NOT NULL,
    avatar_url text,
    role text DEFAULT 'user'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    beta_features text[] DEFAULT ARRAY[]::text[] NOT NULL,
    account_id uuid NOT NULL,
    account_role wa.account_role_enum NOT NULL
);


--
-- Name: quick_replies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.quick_replies (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    account_id uuid NOT NULL,
    user_id uuid NOT NULL,
    title text NOT NULL,
    kind text DEFAULT 'text'::text NOT NULL,
    content_text text,
    interactive_payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT quick_replies_kind_check CHECK ((kind = ANY (ARRAY['text'::text, 'interactive'::text])))
);


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.tags (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    color text DEFAULT '#3b82f6'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    account_id uuid NOT NULL
);


--
-- Name: webhook_endpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.webhook_endpoints (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    created_by uuid,
    url text NOT NULL,
    secret text NOT NULL,
    events text[] DEFAULT '{}'::text[] NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_delivery_at timestamp with time zone,
    failure_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: whatsapp_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE wa.whatsapp_config (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    user_id uuid NOT NULL,
    phone_number_id text NOT NULL,
    waba_id text,
    access_token text NOT NULL,
    verify_token text,
    status text DEFAULT 'disconnected'::text NOT NULL,
    connected_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    registered_at timestamp with time zone,
    subscribed_apps_at timestamp with time zone,
    last_registration_error text,
    account_id uuid NOT NULL,
    mirror_inbound_media boolean DEFAULT true NOT NULL,
    CONSTRAINT whatsapp_config_status_check CHECK ((status = ANY (ARRAY['connected'::text, 'disconnected'::text])))
);


--
-- Name: COLUMN whatsapp_config.mirror_inbound_media; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN wa.whatsapp_config.mirror_inbound_media IS 'When true (default), the inbound webhook copies received media into the chat-media bucket so it outlives Meta''s ~30-day retention. Turn off to keep storage flat and accept that attachments expire.';


--
-- Name: account_invitations account_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.account_invitations
    ADD CONSTRAINT account_invitations_pkey PRIMARY KEY (id);


--
-- Name: account_invitations account_invitations_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.account_invitations
    ADD CONSTRAINT account_invitations_token_hash_key UNIQUE (token_hash);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: ai_configs ai_configs_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_configs
    ADD CONSTRAINT ai_configs_account_id_key UNIQUE (account_id);


--
-- Name: ai_configs ai_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_configs
    ADD CONSTRAINT ai_configs_pkey PRIMARY KEY (id);


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_knowledge_chunks
    ADD CONSTRAINT ai_knowledge_chunks_pkey PRIMARY KEY (id);


--
-- Name: ai_knowledge_documents ai_knowledge_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_knowledge_documents
    ADD CONSTRAINT ai_knowledge_documents_pkey PRIMARY KEY (id);


--
-- Name: ai_usage_log ai_usage_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_usage_log
    ADD CONSTRAINT ai_usage_log_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_key_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.api_keys
    ADD CONSTRAINT api_keys_key_hash_key UNIQUE (key_hash);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: automation_logs automation_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_logs
    ADD CONSTRAINT automation_logs_pkey PRIMARY KEY (id);


--
-- Name: automation_pending_executions automation_pending_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_pkey PRIMARY KEY (id);


--
-- Name: automation_steps automation_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_steps
    ADD CONSTRAINT automation_steps_pkey PRIMARY KEY (id);


--
-- Name: automations automations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automations
    ADD CONSTRAINT automations_pkey PRIMARY KEY (id);


--
-- Name: broadcast_recipients broadcast_recipients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.broadcast_recipients
    ADD CONSTRAINT broadcast_recipients_pkey PRIMARY KEY (id);


--
-- Name: broadcasts broadcasts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.broadcasts
    ADD CONSTRAINT broadcasts_pkey PRIMARY KEY (id);


--
-- Name: contact_custom_values contact_custom_values_contact_id_custom_field_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_custom_values
    ADD CONSTRAINT contact_custom_values_contact_id_custom_field_id_key UNIQUE (contact_id, custom_field_id);


--
-- Name: contact_custom_values contact_custom_values_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_custom_values
    ADD CONSTRAINT contact_custom_values_pkey PRIMARY KEY (id);


--
-- Name: contact_notes contact_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_notes
    ADD CONSTRAINT contact_notes_pkey PRIMARY KEY (id);


--
-- Name: contact_tags contact_tags_contact_id_tag_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_tags
    ADD CONSTRAINT contact_tags_contact_id_tag_id_key UNIQUE (contact_id, tag_id);


--
-- Name: contact_tags contact_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_tags
    ADD CONSTRAINT contact_tags_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: custom_fields custom_fields_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.custom_fields
    ADD CONSTRAINT custom_fields_pkey PRIMARY KEY (id);


--
-- Name: deals deals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_pkey PRIMARY KEY (id);


--
-- Name: flow_nodes flow_nodes_flow_id_node_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_nodes
    ADD CONSTRAINT flow_nodes_flow_id_node_key_key UNIQUE (flow_id, node_key);


--
-- Name: flow_nodes flow_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_nodes
    ADD CONSTRAINT flow_nodes_pkey PRIMARY KEY (id);


--
-- Name: flow_run_events flow_run_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_run_events
    ADD CONSTRAINT flow_run_events_pkey PRIMARY KEY (id);


--
-- Name: flow_runs flow_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_pkey PRIMARY KEY (id);


--
-- Name: flows flows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flows
    ADD CONSTRAINT flows_pkey PRIMARY KEY (id);


--
-- Name: member_presence member_presence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.member_presence
    ADD CONSTRAINT member_presence_pkey PRIMARY KEY (user_id);


--
-- Name: message_reactions message_reactions_message_id_actor_type_actor_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_reactions
    ADD CONSTRAINT message_reactions_message_id_actor_type_actor_id_key UNIQUE (message_id, actor_type, actor_id);


--
-- Name: message_reactions message_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_reactions
    ADD CONSTRAINT message_reactions_pkey PRIMARY KEY (id);


--
-- Name: message_templates message_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_templates
    ADD CONSTRAINT message_templates_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: pipeline_stages pipeline_stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.pipeline_stages
    ADD CONSTRAINT pipeline_stages_pkey PRIMARY KEY (id);


--
-- Name: pipelines pipelines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.pipelines
    ADD CONSTRAINT pipelines_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.profiles
    ADD CONSTRAINT profiles_user_id_key UNIQUE (user_id);


--
-- Name: quick_replies quick_replies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.quick_replies
    ADD CONSTRAINT quick_replies_pkey PRIMARY KEY (id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: webhook_endpoints webhook_endpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.webhook_endpoints
    ADD CONSTRAINT webhook_endpoints_pkey PRIMARY KEY (id);


--
-- Name: whatsapp_config whatsapp_config_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.whatsapp_config
    ADD CONSTRAINT whatsapp_config_account_id_key UNIQUE (account_id);


--
-- Name: whatsapp_config whatsapp_config_phone_number_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.whatsapp_config
    ADD CONSTRAINT whatsapp_config_phone_number_id_key UNIQUE (phone_number_id);


--
-- Name: whatsapp_config whatsapp_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.whatsapp_config
    ADD CONSTRAINT whatsapp_config_pkey PRIMARY KEY (id);


--
-- Name: ai_knowledge_chunks_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_knowledge_chunks_account_id_idx ON wa.ai_knowledge_chunks USING btree (account_id);


--
-- Name: ai_knowledge_chunks_document_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_knowledge_chunks_document_id_idx ON wa.ai_knowledge_chunks USING btree (document_id);


--
-- Name: ai_knowledge_chunks_embedding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_knowledge_chunks_embedding_idx ON wa.ai_knowledge_chunks USING hnsw (embedding extensions.vector_cosine_ops);


--
-- Name: ai_knowledge_chunks_fts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_knowledge_chunks_fts_idx ON wa.ai_knowledge_chunks USING gin (fts);


--
-- Name: ai_knowledge_documents_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_knowledge_documents_account_id_idx ON wa.ai_knowledge_documents USING btree (account_id);


--
-- Name: api_keys_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_keys_account_id_idx ON wa.api_keys USING btree (account_id);


--
-- Name: api_keys_key_hash_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX api_keys_key_hash_idx ON wa.api_keys USING btree (key_hash);


--
-- Name: idx_account_invitations_account_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_invitations_account_pending ON wa.account_invitations USING btree (account_id, expires_at) WHERE (accepted_at IS NULL);


--
-- Name: idx_accounts_one_per_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_accounts_one_per_owner ON wa.accounts USING btree (owner_user_id);


--
-- Name: idx_ai_usage_log_account_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_usage_log_account_created ON wa.ai_usage_log USING btree (account_id, created_at DESC);


--
-- Name: idx_automation_logs_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_logs_account ON wa.automation_logs USING btree (account_id);


--
-- Name: idx_automation_logs_automation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_logs_automation ON wa.automation_logs USING btree (automation_id, created_at DESC);


--
-- Name: idx_automation_logs_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_logs_user ON wa.automation_logs USING btree (user_id);


--
-- Name: idx_automation_pending_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_pending_account ON wa.automation_pending_executions USING btree (account_id);


--
-- Name: idx_automation_pending_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_pending_due ON wa.automation_pending_executions USING btree (run_at) WHERE (status = 'pending'::text);


--
-- Name: idx_automation_steps_automation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_steps_automation_id ON wa.automation_steps USING btree (automation_id, "position");


--
-- Name: idx_automation_steps_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automation_steps_parent ON wa.automation_steps USING btree (parent_step_id) WHERE (parent_step_id IS NOT NULL);


--
-- Name: idx_automations_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automations_account ON wa.automations USING btree (account_id);


--
-- Name: idx_automations_account_active_trigger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automations_account_active_trigger ON wa.automations USING btree (account_id, trigger_type) WHERE (is_active = true);


--
-- Name: idx_automations_active_trigger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automations_active_trigger ON wa.automations USING btree (trigger_type) WHERE (is_active = true);


--
-- Name: idx_automations_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_automations_user_id ON wa.automations USING btree (user_id);


--
-- Name: idx_broadcast_recipients_broadcast; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcast_recipients_broadcast ON wa.broadcast_recipients USING btree (broadcast_id);


--
-- Name: idx_broadcast_recipients_broadcast_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcast_recipients_broadcast_status ON wa.broadcast_recipients USING btree (broadcast_id, status);


--
-- Name: idx_broadcast_recipients_wamid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_broadcast_recipients_wamid ON wa.broadcast_recipients USING btree (whatsapp_message_id) WHERE (whatsapp_message_id IS NOT NULL);


--
-- Name: idx_broadcasts_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_broadcasts_account ON wa.broadcasts USING btree (account_id);


--
-- Name: idx_contact_notes_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contact_notes_account ON wa.contact_notes USING btree (account_id);


--
-- Name: idx_contact_tags_contact; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contact_tags_contact ON wa.contact_tags USING btree (contact_id);


--
-- Name: idx_contact_tags_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contact_tags_tag ON wa.contact_tags USING btree (tag_id);


--
-- Name: idx_contacts_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contacts_account ON wa.contacts USING btree (account_id);


--
-- Name: idx_contacts_account_phone_normalized; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_contacts_account_phone_normalized ON wa.contacts USING btree (account_id, phone_normalized) WHERE (phone_normalized <> ''::text);


--
-- Name: idx_contacts_account_wa_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_contacts_account_wa_user_id ON wa.contacts USING btree (account_id, wa_user_id) WHERE (wa_user_id IS NOT NULL);


--
-- Name: idx_contacts_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contacts_phone ON wa.contacts USING btree (phone);


--
-- Name: idx_contacts_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contacts_user_id ON wa.contacts USING btree (user_id);


--
-- Name: idx_conversations_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_conversations_account ON wa.conversations USING btree (account_id);


--
-- Name: idx_conversations_account_contact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_conversations_account_contact ON wa.conversations USING btree (account_id, contact_id);


--
-- Name: idx_conversations_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_conversations_contact_id ON wa.conversations USING btree (contact_id);


--
-- Name: idx_conversations_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_conversations_user_id ON wa.conversations USING btree (user_id);


--
-- Name: idx_custom_fields_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_custom_fields_account ON wa.custom_fields USING btree (account_id);


--
-- Name: idx_deals_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deals_account ON wa.deals USING btree (account_id);


--
-- Name: idx_deals_assigned_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deals_assigned_to ON wa.deals USING btree (assigned_to);


--
-- Name: idx_deals_pipeline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deals_pipeline ON wa.deals USING btree (pipeline_id);


--
-- Name: idx_deals_stage; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deals_stage ON wa.deals USING btree (stage_id);


--
-- Name: idx_flow_nodes_flow; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flow_nodes_flow ON wa.flow_nodes USING btree (flow_id);


--
-- Name: idx_flow_run_events_run_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flow_run_events_run_time ON wa.flow_run_events USING btree (flow_run_id, created_at DESC);


--
-- Name: idx_flow_run_events_run_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flow_run_events_run_type ON wa.flow_run_events USING btree (flow_run_id, event_type);


--
-- Name: idx_flow_runs_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flow_runs_account ON wa.flow_runs USING btree (account_id);


--
-- Name: idx_flow_runs_active_advanced; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flow_runs_active_advanced ON wa.flow_runs USING btree (last_advanced_at) WHERE (status = 'active'::text);


--
-- Name: idx_flow_runs_flow_started; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flow_runs_flow_started ON wa.flow_runs USING btree (flow_id, started_at DESC);


--
-- Name: idx_flows_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flows_account ON wa.flows USING btree (account_id);


--
-- Name: idx_flows_account_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flows_account_active ON wa.flows USING btree (account_id) WHERE (status = 'active'::text);


--
-- Name: idx_flows_active_trigger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_flows_active_trigger ON wa.flows USING btree (user_id, trigger_type) WHERE (status = 'active'::text);


--
-- Name: idx_message_reactions_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_reactions_conversation ON wa.message_reactions USING btree (conversation_id);


--
-- Name: idx_message_reactions_message; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_reactions_message ON wa.message_reactions USING btree (message_id);


--
-- Name: idx_message_templates_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_templates_account ON wa.message_templates USING btree (account_id);


--
-- Name: idx_message_templates_meta_template_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_message_templates_meta_template_id ON wa.message_templates USING btree (meta_template_id) WHERE (meta_template_id IS NOT NULL);


--
-- Name: idx_messages_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_conversation ON wa.messages USING btree (conversation_id);


--
-- Name: idx_messages_conversation_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_messages_conversation_message_id ON wa.messages USING btree (conversation_id, message_id);


--
-- Name: idx_messages_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_message_id ON wa.messages USING btree (message_id);


--
-- Name: idx_messages_reply_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_reply_to ON wa.messages USING btree (reply_to_message_id) WHERE (reply_to_message_id IS NOT NULL);


--
-- Name: idx_notifications_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_created ON wa.notifications USING btree (user_id, created_at DESC);


--
-- Name: idx_notifications_user_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_unread ON wa.notifications USING btree (user_id) WHERE (read_at IS NULL);


--
-- Name: idx_one_active_run_per_contact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_one_active_run_per_contact ON wa.flow_runs USING btree (account_id, contact_id) WHERE (status = 'active'::text);


--
-- Name: idx_pipeline_stages_pipeline; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pipeline_stages_pipeline ON wa.pipeline_stages USING btree (pipeline_id);


--
-- Name: idx_pipelines_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pipelines_account ON wa.pipelines USING btree (account_id);


--
-- Name: idx_profiles_account_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_account_role ON wa.profiles USING btree (account_id, account_role);


--
-- Name: idx_quick_replies_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quick_replies_account ON wa.quick_replies USING btree (account_id);


--
-- Name: idx_tags_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tags_account ON wa.tags USING btree (account_id);


--
-- Name: idx_whatsapp_config_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_whatsapp_config_account ON wa.whatsapp_config USING btree (account_id);


--
-- Name: idx_whatsapp_config_registered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_whatsapp_config_registered_at ON wa.whatsapp_config USING btree (registered_at) WHERE (registered_at IS NULL);


--
-- Name: member_presence_account_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX member_presence_account_idx ON wa.member_presence USING btree (account_id);


--
-- Name: message_templates_user_name_language_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX message_templates_user_name_language_key ON wa.message_templates USING btree (user_id, name, language);


--
-- Name: webhook_endpoints_account_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_endpoints_account_id_idx ON wa.webhook_endpoints USING btree (account_id);


--
-- Name: ai_configs ai_configs_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_configs_updated_at BEFORE UPDATE ON wa.ai_configs FOR EACH ROW EXECUTE FUNCTION wa.update_ai_configs_updated_at();


--
-- Name: ai_knowledge_documents ai_knowledge_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_knowledge_documents_updated_at BEFORE UPDATE ON wa.ai_knowledge_documents FOR EACH ROW EXECUTE FUNCTION wa.update_ai_knowledge_documents_updated_at();


--
-- Name: broadcast_recipients broadcast_recipients_aggregate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER broadcast_recipients_aggregate AFTER INSERT OR DELETE OR UPDATE ON wa.broadcast_recipients FOR EACH ROW EXECUTE FUNCTION wa.broadcast_recipient_aggregate_trigger();


--
-- Name: profiles enforce_profile_privilege_columns; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_profile_privilege_columns BEFORE UPDATE ON wa.profiles FOR EACH ROW EXECUTE FUNCTION wa.enforce_profile_privilege_columns();


--
-- Name: conversations on_conversation_assigned; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER on_conversation_assigned AFTER INSERT OR UPDATE OF assigned_agent_id ON wa.conversations FOR EACH ROW EXECUTE FUNCTION wa.notify_conversation_assigned();


--
-- Name: accounts set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.accounts FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: automations set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.automations FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: broadcasts set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.broadcasts FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: contacts set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.contacts FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: conversations set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.conversations FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: deals set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.deals FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: flows set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.flows FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: message_templates set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.message_templates FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: profiles set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.profiles FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: quick_replies set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.quick_replies FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: whatsapp_config set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON wa.whatsapp_config FOR EACH ROW EXECUTE FUNCTION wa.update_updated_at_column();


--
-- Name: account_invitations account_invitations_accepted_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.account_invitations
    ADD CONSTRAINT account_invitations_accepted_by_user_id_fkey FOREIGN KEY (accepted_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: account_invitations account_invitations_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.account_invitations
    ADD CONSTRAINT account_invitations_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: account_invitations account_invitations_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.account_invitations
    ADD CONSTRAINT account_invitations_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: accounts accounts_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.accounts
    ADD CONSTRAINT accounts_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: ai_configs ai_configs_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_configs
    ADD CONSTRAINT ai_configs_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: ai_configs ai_configs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_configs
    ADD CONSTRAINT ai_configs_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: ai_configs ai_configs_handoff_agent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_configs
    ADD CONSTRAINT ai_configs_handoff_agent_id_fkey FOREIGN KEY (handoff_agent_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_knowledge_chunks
    ADD CONSTRAINT ai_knowledge_chunks_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_document_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_knowledge_chunks
    ADD CONSTRAINT ai_knowledge_chunks_document_id_fkey FOREIGN KEY (document_id) REFERENCES wa.ai_knowledge_documents(id) ON DELETE CASCADE;


--
-- Name: ai_knowledge_documents ai_knowledge_documents_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_knowledge_documents
    ADD CONSTRAINT ai_knowledge_documents_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: ai_knowledge_documents ai_knowledge_documents_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_knowledge_documents
    ADD CONSTRAINT ai_knowledge_documents_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: ai_usage_log ai_usage_log_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_usage_log
    ADD CONSTRAINT ai_usage_log_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: ai_usage_log ai_usage_log_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.ai_usage_log
    ADD CONSTRAINT ai_usage_log_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES wa.conversations(id) ON DELETE SET NULL;


--
-- Name: api_keys api_keys_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.api_keys
    ADD CONSTRAINT api_keys_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: api_keys api_keys_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.api_keys
    ADD CONSTRAINT api_keys_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: automation_logs automation_logs_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_logs
    ADD CONSTRAINT automation_logs_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: automation_logs automation_logs_automation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_logs
    ADD CONSTRAINT automation_logs_automation_id_fkey FOREIGN KEY (automation_id) REFERENCES wa.automations(id) ON DELETE CASCADE;


--
-- Name: automation_logs automation_logs_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_logs
    ADD CONSTRAINT automation_logs_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE SET NULL;


--
-- Name: automation_logs automation_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_logs
    ADD CONSTRAINT automation_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: automation_pending_executions automation_pending_executions_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: automation_pending_executions automation_pending_executions_automation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_automation_id_fkey FOREIGN KEY (automation_id) REFERENCES wa.automations(id) ON DELETE CASCADE;


--
-- Name: automation_pending_executions automation_pending_executions_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE SET NULL;


--
-- Name: automation_pending_executions automation_pending_executions_log_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_log_id_fkey FOREIGN KEY (log_id) REFERENCES wa.automation_logs(id) ON DELETE CASCADE;


--
-- Name: automation_pending_executions automation_pending_executions_parent_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_parent_step_id_fkey FOREIGN KEY (parent_step_id) REFERENCES wa.automation_steps(id) ON DELETE SET NULL;


--
-- Name: automation_pending_executions automation_pending_executions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_pending_executions
    ADD CONSTRAINT automation_pending_executions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: automation_steps automation_steps_automation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_steps
    ADD CONSTRAINT automation_steps_automation_id_fkey FOREIGN KEY (automation_id) REFERENCES wa.automations(id) ON DELETE CASCADE;


--
-- Name: automation_steps automation_steps_parent_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automation_steps
    ADD CONSTRAINT automation_steps_parent_step_id_fkey FOREIGN KEY (parent_step_id) REFERENCES wa.automation_steps(id) ON DELETE CASCADE;


--
-- Name: automations automations_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automations
    ADD CONSTRAINT automations_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: automations automations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.automations
    ADD CONSTRAINT automations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: broadcast_recipients broadcast_recipients_broadcast_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.broadcast_recipients
    ADD CONSTRAINT broadcast_recipients_broadcast_id_fkey FOREIGN KEY (broadcast_id) REFERENCES wa.broadcasts(id) ON DELETE CASCADE;


--
-- Name: broadcast_recipients broadcast_recipients_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.broadcast_recipients
    ADD CONSTRAINT broadcast_recipients_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE SET NULL;


--
-- Name: broadcasts broadcasts_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.broadcasts
    ADD CONSTRAINT broadcasts_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: broadcasts broadcasts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.broadcasts
    ADD CONSTRAINT broadcasts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: contact_custom_values contact_custom_values_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_custom_values
    ADD CONSTRAINT contact_custom_values_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE CASCADE;


--
-- Name: contact_custom_values contact_custom_values_custom_field_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_custom_values
    ADD CONSTRAINT contact_custom_values_custom_field_id_fkey FOREIGN KEY (custom_field_id) REFERENCES wa.custom_fields(id) ON DELETE CASCADE;


--
-- Name: contact_notes contact_notes_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_notes
    ADD CONSTRAINT contact_notes_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: contact_notes contact_notes_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_notes
    ADD CONSTRAINT contact_notes_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE CASCADE;


--
-- Name: contact_notes contact_notes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_notes
    ADD CONSTRAINT contact_notes_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: contact_tags contact_tags_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_tags
    ADD CONSTRAINT contact_tags_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE CASCADE;


--
-- Name: contact_tags contact_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contact_tags
    ADD CONSTRAINT contact_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES wa.tags(id) ON DELETE CASCADE;


--
-- Name: contacts contacts_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contacts
    ADD CONSTRAINT contacts_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: contacts contacts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.contacts
    ADD CONSTRAINT contacts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: conversations conversations_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.conversations
    ADD CONSTRAINT conversations_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: conversations conversations_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.conversations
    ADD CONSTRAINT conversations_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE CASCADE;


--
-- Name: conversations conversations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.conversations
    ADD CONSTRAINT conversations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: custom_fields custom_fields_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.custom_fields
    ADD CONSTRAINT custom_fields_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: custom_fields custom_fields_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.custom_fields
    ADD CONSTRAINT custom_fields_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: deals deals_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: deals deals_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES wa.profiles(id) ON DELETE SET NULL;


--
-- Name: deals deals_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE SET NULL;


--
-- Name: deals deals_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES wa.conversations(id);


--
-- Name: deals deals_pipeline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_pipeline_id_fkey FOREIGN KEY (pipeline_id) REFERENCES wa.pipelines(id) ON DELETE CASCADE;


--
-- Name: deals deals_stage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_stage_id_fkey FOREIGN KEY (stage_id) REFERENCES wa.pipeline_stages(id);


--
-- Name: deals deals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.deals
    ADD CONSTRAINT deals_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: flow_nodes flow_nodes_flow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_nodes
    ADD CONSTRAINT flow_nodes_flow_id_fkey FOREIGN KEY (flow_id) REFERENCES wa.flows(id) ON DELETE CASCADE;


--
-- Name: flow_run_events flow_run_events_flow_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_run_events
    ADD CONSTRAINT flow_run_events_flow_run_id_fkey FOREIGN KEY (flow_run_id) REFERENCES wa.flow_runs(id) ON DELETE CASCADE;


--
-- Name: flow_runs flow_runs_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: flow_runs flow_runs_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE SET NULL;


--
-- Name: flow_runs flow_runs_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES wa.conversations(id) ON DELETE SET NULL;


--
-- Name: flow_runs flow_runs_flow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_flow_id_fkey FOREIGN KEY (flow_id) REFERENCES wa.flows(id) ON DELETE CASCADE;


--
-- Name: flow_runs flow_runs_last_prompt_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_last_prompt_message_id_fkey FOREIGN KEY (last_prompt_message_id) REFERENCES wa.messages(id) ON DELETE SET NULL;


--
-- Name: flow_runs flow_runs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flow_runs
    ADD CONSTRAINT flow_runs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: flows flows_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flows
    ADD CONSTRAINT flows_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: flows flows_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.flows
    ADD CONSTRAINT flows_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: member_presence member_presence_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.member_presence
    ADD CONSTRAINT member_presence_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: member_presence member_presence_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.member_presence
    ADD CONSTRAINT member_presence_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: message_reactions message_reactions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_reactions
    ADD CONSTRAINT message_reactions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES wa.conversations(id) ON DELETE CASCADE;


--
-- Name: message_reactions message_reactions_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_reactions
    ADD CONSTRAINT message_reactions_message_id_fkey FOREIGN KEY (message_id) REFERENCES wa.messages(id) ON DELETE CASCADE;


--
-- Name: message_templates message_templates_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_templates
    ADD CONSTRAINT message_templates_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: message_templates message_templates_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.message_templates
    ADD CONSTRAINT message_templates_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES wa.conversations(id) ON DELETE CASCADE;


--
-- Name: messages messages_reply_to_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.messages
    ADD CONSTRAINT messages_reply_to_message_id_fkey FOREIGN KEY (reply_to_message_id) REFERENCES wa.messages(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.notifications
    ADD CONSTRAINT notifications_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.notifications
    ADD CONSTRAINT notifications_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_contact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.notifications
    ADD CONSTRAINT notifications_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES wa.contacts(id) ON DELETE SET NULL;


--
-- Name: notifications notifications_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.notifications
    ADD CONSTRAINT notifications_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES wa.conversations(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: pipeline_stages pipeline_stages_pipeline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.pipeline_stages
    ADD CONSTRAINT pipeline_stages_pipeline_id_fkey FOREIGN KEY (pipeline_id) REFERENCES wa.pipelines(id) ON DELETE CASCADE;


--
-- Name: pipelines pipelines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.pipelines
    ADD CONSTRAINT pipelines_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: pipelines pipelines_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.pipelines
    ADD CONSTRAINT pipelines_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.profiles
    ADD CONSTRAINT profiles_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.profiles
    ADD CONSTRAINT profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: quick_replies quick_replies_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.quick_replies
    ADD CONSTRAINT quick_replies_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: quick_replies quick_replies_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.quick_replies
    ADD CONSTRAINT quick_replies_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tags tags_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.tags
    ADD CONSTRAINT tags_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: tags tags_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.tags
    ADD CONSTRAINT tags_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: webhook_endpoints webhook_endpoints_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.webhook_endpoints
    ADD CONSTRAINT webhook_endpoints_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: webhook_endpoints webhook_endpoints_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.webhook_endpoints
    ADD CONSTRAINT webhook_endpoints_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: whatsapp_config whatsapp_config_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.whatsapp_config
    ADD CONSTRAINT whatsapp_config_account_id_fkey FOREIGN KEY (account_id) REFERENCES wa.accounts(id) ON DELETE CASCADE;


--
-- Name: whatsapp_config whatsapp_config_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY wa.whatsapp_config
    ADD CONSTRAINT whatsapp_config_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: account_invitations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.account_invitations ENABLE ROW LEVEL SECURITY;

--
-- Name: account_invitations account_invitations_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY account_invitations_modify ON wa.account_invitations USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum)) WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: account_invitations account_invitations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY account_invitations_select ON wa.account_invitations FOR SELECT USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts accounts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY accounts_select ON wa.accounts FOR SELECT USING (wa.is_account_member(id));


--
-- Name: accounts accounts_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY accounts_update ON wa.accounts FOR UPDATE USING (wa.is_account_member(id, 'admin'::wa.account_role_enum)) WITH CHECK (wa.is_account_member(id, 'admin'::wa.account_role_enum));


--
-- Name: ai_configs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.ai_configs ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_configs ai_configs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_configs_delete ON wa.ai_configs FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_configs ai_configs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_configs_insert ON wa.ai_configs FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_configs ai_configs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_configs_select ON wa.ai_configs FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: ai_configs ai_configs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_configs_update ON wa.ai_configs FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_knowledge_chunks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.ai_knowledge_chunks ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_chunks_delete ON wa.ai_knowledge_chunks FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_chunks_insert ON wa.ai_knowledge_chunks FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_chunks_select ON wa.ai_knowledge_chunks FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_chunks_update ON wa.ai_knowledge_chunks FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_knowledge_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.ai_knowledge_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_knowledge_documents ai_knowledge_documents_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_documents_delete ON wa.ai_knowledge_documents FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_knowledge_documents ai_knowledge_documents_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_documents_insert ON wa.ai_knowledge_documents FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_knowledge_documents ai_knowledge_documents_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_documents_select ON wa.ai_knowledge_documents FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: ai_knowledge_documents ai_knowledge_documents_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_knowledge_documents_update ON wa.ai_knowledge_documents FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: ai_usage_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.ai_usage_log ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_usage_log ai_usage_log_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_usage_log_select ON wa.ai_usage_log FOR SELECT USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: api_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.api_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: api_keys api_keys_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY api_keys_delete ON wa.api_keys FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: api_keys api_keys_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY api_keys_insert ON wa.api_keys FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: api_keys api_keys_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY api_keys_select ON wa.api_keys FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: api_keys api_keys_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY api_keys_update ON wa.api_keys FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: automation_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.automation_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: automation_logs automation_logs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automation_logs_select ON wa.automation_logs FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: automation_pending_executions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.automation_pending_executions ENABLE ROW LEVEL SECURITY;

--
-- Name: automation_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.automation_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: automation_steps automation_steps_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automation_steps_modify ON wa.automation_steps USING ((EXISTS ( SELECT 1
   FROM wa.automations a
  WHERE ((a.id = automation_steps.automation_id) AND wa.is_account_member(a.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.automations a
  WHERE ((a.id = automation_steps.automation_id) AND wa.is_account_member(a.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: automation_steps automation_steps_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automation_steps_select ON wa.automation_steps FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.automations a
  WHERE ((a.id = automation_steps.automation_id) AND wa.is_account_member(a.account_id)))));


--
-- Name: automations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.automations ENABLE ROW LEVEL SECURITY;

--
-- Name: automations automations_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automations_delete ON wa.automations FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: automations automations_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automations_insert ON wa.automations FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: automations automations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automations_select ON wa.automations FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: automations automations_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY automations_update ON wa.automations FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: broadcast_recipients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.broadcast_recipients ENABLE ROW LEVEL SECURITY;

--
-- Name: broadcast_recipients broadcast_recipients_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY broadcast_recipients_modify ON wa.broadcast_recipients USING ((EXISTS ( SELECT 1
   FROM wa.broadcasts b
  WHERE ((b.id = broadcast_recipients.broadcast_id) AND wa.is_account_member(b.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.broadcasts b
  WHERE ((b.id = broadcast_recipients.broadcast_id) AND wa.is_account_member(b.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: broadcast_recipients broadcast_recipients_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY broadcast_recipients_select ON wa.broadcast_recipients FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.broadcasts b
  WHERE ((b.id = broadcast_recipients.broadcast_id) AND wa.is_account_member(b.account_id)))));


--
-- Name: broadcasts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.broadcasts ENABLE ROW LEVEL SECURITY;

--
-- Name: broadcasts broadcasts_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY broadcasts_delete ON wa.broadcasts FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: broadcasts broadcasts_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY broadcasts_insert ON wa.broadcasts FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: broadcasts broadcasts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY broadcasts_select ON wa.broadcasts FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: broadcasts broadcasts_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY broadcasts_update ON wa.broadcasts FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: contact_custom_values; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.contact_custom_values ENABLE ROW LEVEL SECURITY;

--
-- Name: contact_custom_values contact_custom_values_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_custom_values_modify ON wa.contact_custom_values USING ((EXISTS ( SELECT 1
   FROM wa.contacts c
  WHERE ((c.id = contact_custom_values.contact_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.contacts c
  WHERE ((c.id = contact_custom_values.contact_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: contact_custom_values contact_custom_values_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_custom_values_select ON wa.contact_custom_values FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.contacts c
  WHERE ((c.id = contact_custom_values.contact_id) AND wa.is_account_member(c.account_id)))));


--
-- Name: contact_notes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.contact_notes ENABLE ROW LEVEL SECURITY;

--
-- Name: contact_notes contact_notes_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_notes_delete ON wa.contact_notes FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: contact_notes contact_notes_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_notes_insert ON wa.contact_notes FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: contact_notes contact_notes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_notes_select ON wa.contact_notes FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: contact_notes contact_notes_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_notes_update ON wa.contact_notes FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: contact_tags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.contact_tags ENABLE ROW LEVEL SECURITY;

--
-- Name: contact_tags contact_tags_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_tags_modify ON wa.contact_tags USING ((EXISTS ( SELECT 1
   FROM wa.contacts c
  WHERE ((c.id = contact_tags.contact_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.contacts c
  WHERE ((c.id = contact_tags.contact_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: contact_tags contact_tags_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contact_tags_select ON wa.contact_tags FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.contacts c
  WHERE ((c.id = contact_tags.contact_id) AND wa.is_account_member(c.account_id)))));


--
-- Name: contacts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.contacts ENABLE ROW LEVEL SECURITY;

--
-- Name: contacts contacts_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contacts_delete ON wa.contacts FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: contacts contacts_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contacts_insert ON wa.contacts FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: contacts contacts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contacts_select ON wa.contacts FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: contacts contacts_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contacts_update ON wa.contacts FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations conversations_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY conversations_delete ON wa.conversations FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: conversations conversations_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY conversations_insert ON wa.conversations FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: conversations conversations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY conversations_select ON wa.conversations FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: conversations conversations_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY conversations_update ON wa.conversations FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: custom_fields; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.custom_fields ENABLE ROW LEVEL SECURITY;

--
-- Name: custom_fields custom_fields_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY custom_fields_delete ON wa.custom_fields FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: custom_fields custom_fields_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY custom_fields_insert ON wa.custom_fields FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: custom_fields custom_fields_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY custom_fields_select ON wa.custom_fields FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: custom_fields custom_fields_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY custom_fields_update ON wa.custom_fields FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: deals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.deals ENABLE ROW LEVEL SECURITY;

--
-- Name: deals deals_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deals_delete ON wa.deals FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: deals deals_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deals_insert ON wa.deals FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: deals deals_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deals_select ON wa.deals FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: deals deals_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deals_update ON wa.deals FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: flow_nodes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.flow_nodes ENABLE ROW LEVEL SECURITY;

--
-- Name: flow_nodes flow_nodes_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flow_nodes_modify ON wa.flow_nodes USING ((EXISTS ( SELECT 1
   FROM wa.flows f
  WHERE ((f.id = flow_nodes.flow_id) AND wa.is_account_member(f.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.flows f
  WHERE ((f.id = flow_nodes.flow_id) AND wa.is_account_member(f.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: flow_nodes flow_nodes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flow_nodes_select ON wa.flow_nodes FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.flows f
  WHERE ((f.id = flow_nodes.flow_id) AND wa.is_account_member(f.account_id)))));


--
-- Name: flow_run_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.flow_run_events ENABLE ROW LEVEL SECURITY;

--
-- Name: flow_run_events flow_run_events_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flow_run_events_select ON wa.flow_run_events FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.flow_runs r
  WHERE ((r.id = flow_run_events.flow_run_id) AND wa.is_account_member(r.account_id)))));


--
-- Name: flow_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.flow_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: flow_runs flow_runs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flow_runs_select ON wa.flow_runs FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: flows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.flows ENABLE ROW LEVEL SECURITY;

--
-- Name: flows flows_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flows_delete ON wa.flows FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: flows flows_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flows_insert ON wa.flows FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: flows flows_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flows_select ON wa.flows FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: flows flows_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY flows_update ON wa.flows FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: member_presence; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.member_presence ENABLE ROW LEVEL SECURITY;

--
-- Name: member_presence member_presence_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY member_presence_select ON wa.member_presence FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: message_reactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.message_reactions ENABLE ROW LEVEL SECURITY;

--
-- Name: message_reactions message_reactions_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_reactions_modify ON wa.message_reactions USING ((EXISTS ( SELECT 1
   FROM (wa.messages m
     JOIN wa.conversations c ON ((c.id = m.conversation_id)))
  WHERE ((m.id = message_reactions.message_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (wa.messages m
     JOIN wa.conversations c ON ((c.id = m.conversation_id)))
  WHERE ((m.id = message_reactions.message_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: message_reactions message_reactions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_reactions_select ON wa.message_reactions FOR SELECT USING ((EXISTS ( SELECT 1
   FROM (wa.messages m
     JOIN wa.conversations c ON ((c.id = m.conversation_id)))
  WHERE ((m.id = message_reactions.message_id) AND wa.is_account_member(c.account_id)))));


--
-- Name: message_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.message_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: message_templates message_templates_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_templates_delete ON wa.message_templates FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: message_templates message_templates_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_templates_insert ON wa.message_templates FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: message_templates message_templates_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_templates_select ON wa.message_templates FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: message_templates message_templates_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY message_templates_update ON wa.message_templates FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: messages messages_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY messages_modify ON wa.messages USING ((EXISTS ( SELECT 1
   FROM wa.conversations c
  WHERE ((c.id = messages.conversation_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.conversations c
  WHERE ((c.id = messages.conversation_id) AND wa.is_account_member(c.account_id, 'agent'::wa.account_role_enum)))));


--
-- Name: messages messages_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY messages_select ON wa.messages FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.conversations c
  WHERE ((c.id = messages.conversation_id) AND wa.is_account_member(c.account_id)))));


--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_select ON wa.notifications FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: notifications notifications_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_update ON wa.notifications FOR UPDATE USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: pipeline_stages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.pipeline_stages ENABLE ROW LEVEL SECURITY;

--
-- Name: pipeline_stages pipeline_stages_modify; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipeline_stages_modify ON wa.pipeline_stages USING ((EXISTS ( SELECT 1
   FROM wa.pipelines p
  WHERE ((p.id = pipeline_stages.pipeline_id) AND wa.is_account_member(p.account_id, 'admin'::wa.account_role_enum))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM wa.pipelines p
  WHERE ((p.id = pipeline_stages.pipeline_id) AND wa.is_account_member(p.account_id, 'admin'::wa.account_role_enum)))));


--
-- Name: pipeline_stages pipeline_stages_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipeline_stages_select ON wa.pipeline_stages FOR SELECT USING ((EXISTS ( SELECT 1
   FROM wa.pipelines p
  WHERE ((p.id = pipeline_stages.pipeline_id) AND wa.is_account_member(p.account_id)))));


--
-- Name: pipelines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.pipelines ENABLE ROW LEVEL SECURITY;

--
-- Name: pipelines pipelines_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipelines_delete ON wa.pipelines FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: pipelines pipelines_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipelines_insert ON wa.pipelines FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: pipelines pipelines_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipelines_select ON wa.pipelines FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: pipelines pipelines_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipelines_update ON wa.pipelines FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_insert ON wa.profiles FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: profiles profiles_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select ON wa.profiles FOR SELECT USING (((auth.uid() = user_id) OR wa.is_account_member(account_id)));


--
-- Name: profiles profiles_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_update ON wa.profiles FOR UPDATE USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: quick_replies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.quick_replies ENABLE ROW LEVEL SECURITY;

--
-- Name: quick_replies quick_replies_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY quick_replies_delete ON wa.quick_replies FOR DELETE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: quick_replies quick_replies_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY quick_replies_insert ON wa.quick_replies FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: quick_replies quick_replies_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY quick_replies_select ON wa.quick_replies FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: quick_replies quick_replies_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY quick_replies_update ON wa.quick_replies FOR UPDATE USING (wa.is_account_member(account_id, 'agent'::wa.account_role_enum));


--
-- Name: tags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.tags ENABLE ROW LEVEL SECURITY;

--
-- Name: tags tags_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tags_delete ON wa.tags FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: tags tags_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tags_insert ON wa.tags FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: tags tags_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tags_select ON wa.tags FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: tags tags_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tags_update ON wa.tags FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: webhook_endpoints; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.webhook_endpoints ENABLE ROW LEVEL SECURITY;

--
-- Name: webhook_endpoints webhook_endpoints_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY webhook_endpoints_delete ON wa.webhook_endpoints FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: webhook_endpoints webhook_endpoints_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY webhook_endpoints_insert ON wa.webhook_endpoints FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: webhook_endpoints webhook_endpoints_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY webhook_endpoints_select ON wa.webhook_endpoints FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: webhook_endpoints webhook_endpoints_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY webhook_endpoints_update ON wa.webhook_endpoints FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: whatsapp_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE wa.whatsapp_config ENABLE ROW LEVEL SECURITY;

--
-- Name: whatsapp_config whatsapp_config_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY whatsapp_config_delete ON wa.whatsapp_config FOR DELETE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: whatsapp_config whatsapp_config_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY whatsapp_config_insert ON wa.whatsapp_config FOR INSERT WITH CHECK (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: whatsapp_config whatsapp_config_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY whatsapp_config_select ON wa.whatsapp_config FOR SELECT USING (wa.is_account_member(account_id));


--
-- Name: whatsapp_config whatsapp_config_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY whatsapp_config_update ON wa.whatsapp_config FOR UPDATE USING (wa.is_account_member(account_id, 'admin'::wa.account_role_enum));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION bump_conversation_on_inbound(p_conversation_id uuid, p_last_message_text text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.bump_conversation_on_inbound(p_conversation_id uuid, p_last_message_text text) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.bump_conversation_on_inbound(p_conversation_id uuid, p_last_message_text text) TO service_role;


--
-- Name: FUNCTION claim_ai_reply_slot(conversation_id uuid, max_replies integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION wa.claim_ai_reply_slot(conversation_id uuid, max_replies integer) TO service_role;


--
-- Name: FUNCTION create_broadcast_with_recipients(p_account_id uuid, p_user_id uuid, p_name text, p_template_name text, p_template_language text, p_total_recipients integer, p_contact_ids uuid[], p_template_params jsonb[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.create_broadcast_with_recipients(p_account_id uuid, p_user_id uuid, p_name text, p_template_name text, p_template_language text, p_total_recipients integer, p_contact_ids uuid[], p_template_params jsonb[]) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.create_broadcast_with_recipients(p_account_id uuid, p_user_id uuid, p_name text, p_template_name text, p_template_language text, p_total_recipients integer, p_contact_ids uuid[], p_template_params jsonb[]) TO service_role;


--
-- Name: FUNCTION filter_contacts_by_tags(p_tag_ids uuid[], p_search text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.filter_contacts_by_tags(p_tag_ids uuid[], p_search text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.filter_contacts_by_tags(p_tag_ids uuid[], p_search text, p_limit integer, p_offset integer) TO authenticated;


--
-- Name: FUNCTION increment_automation_execution_count(p_automation_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.increment_automation_execution_count(p_automation_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.increment_automation_execution_count(p_automation_id uuid) TO service_role;


--
-- Name: FUNCTION increment_flow_execution_count(p_flow_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.increment_flow_execution_count(p_flow_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.increment_flow_execution_count(p_flow_id uuid) TO service_role;


--
-- Name: FUNCTION is_account_member(target_account_id uuid, min_role wa.account_role_enum); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION wa.is_account_member(target_account_id uuid, min_role wa.account_role_enum) TO authenticated;
GRANT ALL ON FUNCTION wa.is_account_member(target_account_id uuid, min_role wa.account_role_enum) TO service_role;


--
-- Name: FUNCTION match_ai_knowledge_fts(p_account_id uuid, p_query text, p_match_count integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.match_ai_knowledge_fts(p_account_id uuid, p_query text, p_match_count integer) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.match_ai_knowledge_fts(p_account_id uuid, p_query text, p_match_count integer) TO authenticated;
GRANT ALL ON FUNCTION wa.match_ai_knowledge_fts(p_account_id uuid, p_query text, p_match_count integer) TO service_role;


--
-- Name: FUNCTION match_ai_knowledge_semantic(p_account_id uuid, p_query_embedding text, p_match_count integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.match_ai_knowledge_semantic(p_account_id uuid, p_query_embedding text, p_match_count integer) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.match_ai_knowledge_semantic(p_account_id uuid, p_query_embedding text, p_match_count integer) TO authenticated;
GRANT ALL ON FUNCTION wa.match_ai_knowledge_semantic(p_account_id uuid, p_query_embedding text, p_match_count integer) TO service_role;


--
-- Name: FUNCTION merge_duplicate_contacts(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.merge_duplicate_contacts() FROM PUBLIC;


--
-- Name: FUNCTION merge_duplicate_conversations(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.merge_duplicate_conversations() FROM PUBLIC;


--
-- Name: FUNCTION peek_invitation(p_token_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.peek_invitation(p_token_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.peek_invitation(p_token_hash text) TO anon;
GRANT ALL ON FUNCTION wa.peek_invitation(p_token_hash text) TO authenticated;


--
-- Name: FUNCTION redeem_invitation(p_token_hash text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.redeem_invitation(p_token_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.redeem_invitation(p_token_hash text) TO authenticated;


--
-- Name: FUNCTION remove_account_member(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.remove_account_member(p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.remove_account_member(p_user_id uuid) TO authenticated;


--
-- Name: FUNCTION set_member_role(p_user_id uuid, p_new_role wa.account_role_enum); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.set_member_role(p_user_id uuid, p_new_role wa.account_role_enum) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.set_member_role(p_user_id uuid, p_new_role wa.account_role_enum) TO authenticated;


--
-- Name: FUNCTION transfer_account_ownership(p_new_owner_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION wa.transfer_account_ownership(p_new_owner_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION wa.transfer_account_ownership(p_new_owner_user_id uuid) TO authenticated;


--
-- Name: COLUMN notifications.read_at; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(read_at) ON TABLE wa.notifications TO authenticated;


--
-- PostgreSQL database dump complete
--


-- ============================================================
-- Storage
--
-- Buckets and their policies live in the `storage` schema, which the
-- relocation does not touch. Only the `profiles` lookups inside the
-- flow-media and chat-media policies had to be re-qualified to `wa`:
-- they were unqualified and would otherwise resolve against whatever
-- the caller's search_path happened to point at.
--
-- `avatars` is now a name taken in Cortex's project. Recorded in the
-- plan's risk table so Cortex does not later claim it.
-- ============================================================
-- Buckets (idempotent — the storage schema is shared with Cortex).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, '{image/png,image/jpeg,image/webp,image/gif}')
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('flow-media', 'flow-media', true, 16777216, '{image/png,image/jpeg,image/webp,video/mp4,video/3gpp,application/pdf,application/vnd.ms-powerpoint,application/msword,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.openxmlformats-officedocument.presentationml.presentation,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/plain}')
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', true, 16777216, '{image/png,image/jpeg,image/webp,image/gif,video/mp4,video/3gpp,video/3gp,video/quicktime,application/pdf,application/vnd.ms-powerpoint,application/msword,application/vnd.ms-excel,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.openxmlformats-officedocument.presentationml.presentation,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,text/plain,audio/ogg,audio/mpeg,audio/aac,audio/mp4,audio/amr,audio/opus}')
on conflict (id) do nothing;

drop policy if exists "Avatars are publicly readable" on storage.objects;
create policy "Avatars are publicly readable" on storage.objects for SELECT to public
  using ((bucket_id = 'avatars'::text));

drop policy if exists "Users can upload their own avatar" on storage.objects;
create policy "Users can upload their own avatar" on storage.objects for INSERT to public
  with check (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));

drop policy if exists "Users can update their own avatar" on storage.objects;
create policy "Users can update their own avatar" on storage.objects for UPDATE to public
  using (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));

drop policy if exists "Users can delete their own avatar" on storage.objects;
create policy "Users can delete their own avatar" on storage.objects for DELETE to public
  using (((bucket_id = 'avatars'::text) AND ((auth.uid())::text = (storage.foldername(name))[1])));

drop policy if exists "Flow media is publicly readable" on storage.objects;
create policy "Flow media is publicly readable" on storage.objects for SELECT to public
  using ((bucket_id = 'flow-media'::text));

drop policy if exists "Members can upload flow media" on storage.objects;
create policy "Members can upload flow media" on storage.objects for INSERT to public
  with check (((bucket_id = 'flow-media'::text) AND ((EXISTS ( SELECT 1
   FROM wa.profiles p
  WHERE ((p.user_id = auth.uid()) AND (('account-'::text || (p.account_id)::text) = (storage.foldername(objects.name))[1])))) OR ((auth.uid())::text = (storage.foldername(name))[1]))));

drop policy if exists "Members can update flow media" on storage.objects;
create policy "Members can update flow media" on storage.objects for UPDATE to public
  using (((bucket_id = 'flow-media'::text) AND ((EXISTS ( SELECT 1
   FROM wa.profiles p
  WHERE ((p.user_id = auth.uid()) AND (('account-'::text || (p.account_id)::text) = (storage.foldername(objects.name))[1])))) OR ((auth.uid())::text = (storage.foldername(name))[1]))));

drop policy if exists "Members can delete flow media" on storage.objects;
create policy "Members can delete flow media" on storage.objects for DELETE to public
  using (((bucket_id = 'flow-media'::text) AND ((EXISTS ( SELECT 1
   FROM wa.profiles p
  WHERE ((p.user_id = auth.uid()) AND (('account-'::text || (p.account_id)::text) = (storage.foldername(objects.name))[1])))) OR ((auth.uid())::text = (storage.foldername(name))[1]))));

drop policy if exists "Chat media is publicly readable" on storage.objects;
create policy "Chat media is publicly readable" on storage.objects for SELECT to public
  using ((bucket_id = 'chat-media'::text));

drop policy if exists "Members can upload chat media" on storage.objects;
create policy "Members can upload chat media" on storage.objects for INSERT to public
  with check (((bucket_id = 'chat-media'::text) AND (EXISTS ( SELECT 1
   FROM wa.profiles p
  WHERE ((p.user_id = auth.uid()) AND (('account-'::text || (p.account_id)::text) = (storage.foldername(objects.name))[1]))))));

drop policy if exists "Members can update chat media" on storage.objects;
create policy "Members can update chat media" on storage.objects for UPDATE to public
  using (((bucket_id = 'chat-media'::text) AND (EXISTS ( SELECT 1
   FROM wa.profiles p
  WHERE ((p.user_id = auth.uid()) AND (('account-'::text || (p.account_id)::text) = (storage.foldername(objects.name))[1]))))));

drop policy if exists "Members can delete chat media" on storage.objects;
create policy "Members can delete chat media" on storage.objects for DELETE to public
  using (((bucket_id = 'chat-media'::text) AND (EXISTS ( SELECT 1
   FROM wa.profiles p
  WHERE ((p.user_id = auth.uid()) AND (('account-'::text || (p.account_id)::text) = (storage.foldername(objects.name))[1]))))));
