--
-- PostgreSQL database dump
--

\restrict u4WYajMkdQyWOncwjkSbc6OhuGPq8U8wXMb7yqLgivfx2Nuir2hWj2YDBJ2PBD0

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: audit; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA audit;


--
-- Name: core; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA core;


--
-- Name: duty; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA duty;


--
-- Name: parse; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA parse;


--
-- Name: personnel; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA personnel;


--
-- Name: forbid_change(); Type: FUNCTION; Schema: audit; Owner: -
--

CREATE FUNCTION audit.forbid_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'Журнал изменений не правится и не удаляется';
END $$;


--
-- Name: log_change(); Type: FUNCTION; Schema: audit; Owner: -
--

CREATE FUNCTION audit.log_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  o jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  n jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
  od jsonb := '{}';
  nd jsonb := '{}';
  k text;
  uid int := nullif(current_setting('app.user_id', true), '')::int;
  noise text[] := ARRAY['password_hash', 'updated_at', 'last_login_at', 'failed_attempts',
                        'locked_until', 'password_changed_at', 'must_change_password'];
BEGIN
  o := o - noise;
  n := n - noise;

  IF TG_OP = 'UPDATE' THEN
    FOR k IN SELECT jsonb_object_keys(n) LOOP
      IF (o -> k) IS DISTINCT FROM (n -> k) THEN
        od := od || jsonb_build_object(k, o -> k);
        nd := nd || jsonb_build_object(k, n -> k);
      END IF;
    END LOOP;
    IF nd = '{}'::jsonb THEN RETURN NULL; END IF;
    IF n ? 'employee_id' THEN nd := nd || jsonb_build_object('employee_id', n -> 'employee_id'); END IF;
    IF n ? 'owner_id' AND NOT nd ? 'owner_id' THEN od := od || jsonb_build_object('owner_id', o -> 'owner_id'); END IF;
    o := od;
    n := nd;
  END IF;

  INSERT INTO audit.changes (user_id, table_name, row_id, action, old_data, new_data)
  VALUES (uid, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
          coalesce(to_jsonb(NEW) ->> 'id', to_jsonb(OLD) ->> 'id'),
          lower(TG_OP), o, n);
  RETURN NULL;
END $$;


--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION core.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


--
-- Name: set_start_date(); Type: FUNCTION; Schema: duty; Owner: -
--

CREATE FUNCTION duty.set_start_date() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN NEW.start_date=NEW.starts_at::date; RETURN NEW; END $$;


--
-- Name: check_permit_post(); Type: FUNCTION; Schema: personnel; Owner: -
--

CREATE FUNCTION personnel.check_permit_post() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    post_specific boolean;
BEGIN
    SELECT is_post_specific INTO post_specific
      FROM personnel.permit_types WHERE id = NEW.permit_type_id;

    IF post_specific AND NEW.post_id IS NULL THEN
        RAISE EXCEPTION 'Допуск этого вида оформляется к посту: поле post_id обязательно';
    END IF;

    IF NOT post_specific AND NEW.post_id IS NOT NULL THEN
        RAISE EXCEPTION 'Допуск этого вида является общим и к посту не привязывается';
    END IF;

    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: employee_permits; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.employee_permits (
    id integer NOT NULL,
    employee_id integer NOT NULL,
    permit_type_id integer NOT NULL,
    issued_at date NOT NULL,
    expires_at date,
    status text DEFAULT 'active'::text NOT NULL,
    suspended_from date,
    suspended_to date,
    suspend_reason text,
    document_ref text,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    post_id integer,
    order_id integer,
    CONSTRAINT permits_dates_ordered CHECK (((expires_at IS NULL) OR (expires_at >= issued_at))),
    CONSTRAINT permits_status_known CHECK ((status = ANY (ARRAY['active'::text, 'suspended'::text, 'revoked'::text]))),
    CONSTRAINT permits_suspend_ordered CHECK (((suspended_to IS NULL) OR (suspended_from IS NULL) OR (suspended_to >= suspended_from)))
);


--
-- Name: permit_is_valid(personnel.employee_permits, date); Type: FUNCTION; Schema: personnel; Owner: -
--

CREATE FUNCTION personnel.permit_is_valid(p personnel.employee_permits, on_date date) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT p.status = 'active'
       AND p.issued_at <= on_date
       AND (p.expires_at IS NULL OR p.expires_at >= on_date)
       AND NOT (
           p.suspended_from IS NOT NULL
           AND p.suspended_from <= on_date
           AND (p.suspended_to IS NULL OR p.suspended_to >= on_date)
       )
$$;


--
-- Name: FUNCTION permit_is_valid(p personnel.employee_permits, on_date date); Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON FUNCTION personnel.permit_is_valid(p personnel.employee_permits, on_date date) IS 'Единственное определение действующего допуска. Дата — параметр: наряды назначаются вперед, и проверять допуск нужно на день заступления, а не на сегодня.';


--
-- Name: change_log; Type: TABLE; Schema: audit; Owner: -
--

CREATE TABLE audit.change_log (
    id bigint NOT NULL,
    schema_name text NOT NULL,
    table_name text NOT NULL,
    record_id text NOT NULL,
    action text NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    document_ref text,
    changed_by integer,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    old_values jsonb,
    new_values jsonb,
    CONSTRAINT audit_action_known CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT audit_source_known CHECK ((source = ANY (ARRAY['manual'::text, 'import'::text])))
);


--
-- Name: change_log_id_seq; Type: SEQUENCE; Schema: audit; Owner: -
--

CREATE SEQUENCE audit.change_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: change_log_id_seq; Type: SEQUENCE OWNED BY; Schema: audit; Owner: -
--

ALTER SEQUENCE audit.change_log_id_seq OWNED BY audit.change_log.id;


--
-- Name: changes; Type: TABLE; Schema: audit; Owner: -
--

CREATE TABLE audit.changes (
    id bigint NOT NULL,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id integer,
    table_name text NOT NULL,
    row_id text,
    action text NOT NULL,
    old_data jsonb,
    new_data jsonb,
    CONSTRAINT changes_action_check CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text])))
);


--
-- Name: changes_id_seq; Type: SEQUENCE; Schema: audit; Owner: -
--

CREATE SEQUENCE audit.changes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: changes_id_seq; Type: SEQUENCE OWNED BY; Schema: audit; Owner: -
--

ALTER SEQUENCE audit.changes_id_seq OWNED BY audit.changes.id;


--
-- Name: acting_commanders; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.acting_commanders (
    id integer NOT NULL,
    unit_id integer NOT NULL,
    employee_id integer NOT NULL,
    date_from date NOT NULL,
    date_to date NOT NULL,
    reason text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    cancelled_at timestamp with time zone,
    CONSTRAINT acting_commanders_check CHECK ((date_to >= date_from))
);


--
-- Name: acting_commanders_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.acting_commanders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: acting_commanders_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.acting_commanders_id_seq OWNED BY core.acting_commanders.id;


--
-- Name: calendar_days; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.calendar_days (
    day date NOT NULL,
    name text,
    kind text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT calendar_kind_known CHECK ((kind = ANY (ARRAY['holiday'::text, 'workday'::text])))
);


--
-- Name: TABLE calendar_days; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.calendar_days IS 'Отклонения от обычной рабочей недели. Суббота и воскресенье нерабочие по умолчанию и здесь не хранятся. Ведется вручную: состав нерабочих дней меняется год от года, переносы объявляются отдельно.';


--
-- Name: COLUMN calendar_days.kind; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON COLUMN core.calendar_days.kind IS 'holiday — нерабочий день (праздник либо объявленный выходной); workday — рабочий день вопреки дню недели (перенос).';


--
-- Name: login_failures; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.login_failures (
    user_id integer NOT NULL,
    ip text NOT NULL,
    failed_attempts integer DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: permissions; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.permissions (
    code text NOT NULL,
    name text NOT NULL,
    section text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: positions; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.positions (
    id integer NOT NULL,
    unit_id integer NOT NULL,
    title text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    employee_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    is_commander boolean DEFAULT false NOT NULL,
    CONSTRAINT positions_title_check CHECK ((length(TRIM(BOTH FROM title)) > 0))
);


--
-- Name: positions_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.positions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: positions_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.positions_id_seq OWNED BY core.positions.id;


--
-- Name: ranks; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.ranks (
    id integer NOT NULL,
    name text NOT NULL,
    short_name text NOT NULL,
    seniority integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


--
-- Name: ranks_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.ranks_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ranks_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.ranks_id_seq OWNED BY core.ranks.id;


--
-- Name: role_permissions; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.role_permissions (
    role_code text NOT NULL,
    permission_code text NOT NULL
);


--
-- Name: roles; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.roles (
    code text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    is_system boolean DEFAULT true NOT NULL
);


--
-- Name: security_events; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.security_events (
    id bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    kind text NOT NULL,
    user_id integer,
    actor_id integer,
    login text,
    detail text,
    ip text
);


--
-- Name: security_events_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.security_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: security_events_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.security_events_id_seq OWNED BY core.security_events.id;


--
-- Name: sessions; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.sessions (
    id text NOT NULL,
    user_id integer NOT NULL,
    csrf_token text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    ip text,
    user_agent text
);


--
-- Name: settings; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.settings (
    key text NOT NULL,
    value numeric NOT NULL,
    name text NOT NULL,
    description text,
    updated_by integer,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: units; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.units (
    id integer NOT NULL,
    name text NOT NULL,
    short_name text NOT NULL,
    parent_id integer,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    commander_employee_id integer,
    staff_count integer,
    is_headquarters boolean DEFAULT false NOT NULL,
    CONSTRAINT units_not_self_parent CHECK ((parent_id IS DISTINCT FROM id)),
    CONSTRAINT units_staff_count_sane CHECK (((staff_count IS NULL) OR (staff_count >= 0)))
);


--
-- Name: COLUMN units.staff_count; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON COLUMN core.units.staff_count IS 'Численность по штату для графы «По штату» строевой записки; NULL — не задана';


--
-- Name: units_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.units_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: units_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.units_id_seq OWNED BY core.units.id;


--
-- Name: user_permissions; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.user_permissions (
    user_id integer NOT NULL,
    permission_code text NOT NULL,
    granted boolean NOT NULL,
    note text,
    granted_by integer,
    granted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.users (
    id integer NOT NULL,
    employee_id integer,
    login text NOT NULL,
    password_hash text NOT NULL,
    role_code text DEFAULT 'admin'::text NOT NULL,
    failed_attempts integer DEFAULT 0 NOT NULL,
    locked_until timestamp with time zone,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    must_change_password boolean DEFAULT false NOT NULL,
    password_changed_at timestamp with time zone,
    last_login_at timestamp with time zone,
    created_by integer,
    scope_unit_id integer,
    CONSTRAINT users_commander_has_unit CHECK (((role_code <> 'commander'::text) OR (scope_unit_id IS NOT NULL)))
);


--
-- Name: COLUMN users.scope_unit_id; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON COLUMN core.users.scope_unit_id IS 'Подразделение, закрепленное за пользователем. Видит и ведет его вместе со всеми вложенными. NULL — вся часть';


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: core; Owner: -
--

CREATE SEQUENCE core.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: core; Owner: -
--

ALTER SEQUENCE core.users_id_seq OWNED BY core.users.id;


--
-- Name: duties; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.duties (
    id integer NOT NULL,
    duty_type_id integer NOT NULL,
    unit_id integer NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    created_by integer,
    approved_by integer,
    approved_at timestamp with time zone,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    unapproved_by integer,
    unapproved_at timestamp with time zone,
    approved_snapshot jsonb,
    order_snapshot jsonb,
    order_deadline date,
    start_date date NOT NULL,
    CONSTRAINT duties_approval_consistent CHECK (((status = 'approved'::text) = (approved_at IS NOT NULL))),
    CONSTRAINT duties_period_ordered CHECK ((ends_at > starts_at)),
    CONSTRAINT duties_status_known CHECK ((status = ANY (ARRAY['draft'::text, 'submitted'::text, 'approved'::text, 'cancelled'::text])))
);


--
-- Name: COLUMN duties.unapproved_by; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duties.unapproved_by IS 'Кто снял утверждение. Утверждение снимается при обнаружении ошибки в составе; сам факт должен оставаться видимым вышестоящим.';


--
-- Name: duties_id_seq; Type: SEQUENCE; Schema: duty; Owner: -
--

CREATE SEQUENCE duty.duties_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: duties_id_seq; Type: SEQUENCE OWNED BY; Schema: duty; Owner: -
--

ALTER SEQUENCE duty.duties_id_seq OWNED BY duty.duties.id;


--
-- Name: duty_assignments; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.duty_assignments (
    id integer NOT NULL,
    duty_id integer NOT NULL,
    employee_id integer NOT NULL,
    is_override boolean DEFAULT false NOT NULL,
    override_reason text,
    override_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    post_id integer NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    note text,
    noted_by integer,
    noted_at timestamp with time zone,
    override_checks text[] DEFAULT '{}'::text[] NOT NULL,
    on_date date,
    weapon_id integer,
    CONSTRAINT assignments_override_has_reason CHECK (((NOT is_override) OR (override_reason IS NOT NULL))),
    CONSTRAINT assignments_source_known CHECK ((source = ANY (ARRAY['manual'::text, 'auto'::text])))
);


--
-- Name: COLUMN duty_assignments.source; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_assignments.source IS 'manual — назначил человек; auto — предложила система, требуется подтверждение начальника.';


--
-- Name: COLUMN duty_assignments.note; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_assignments.note IS 'Примечание к назначению: причина замены, внесенная при утверждении приказа';


--
-- Name: duty_assignments_id_seq; Type: SEQUENCE; Schema: duty; Owner: -
--

CREATE SEQUENCE duty.duty_assignments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: duty_assignments_id_seq; Type: SEQUENCE OWNED BY; Schema: duty; Owner: -
--

ALTER SEQUENCE duty.duty_assignments_id_seq OWNED BY duty.duty_assignments.id;


--
-- Name: duty_posts; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.duty_posts (
    id integer NOT NULL,
    duty_type_id integer NOT NULL,
    unit_id integer,
    short_name text,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    required_permit_type_id integer,
    required_weapon_kind text,
    start_time time without time zone,
    duration_hours integer,
    recovery_sleep_days integer,
    per_day boolean DEFAULT false NOT NULL,
    rotation_since date,
    allow_consecutive boolean,
    CONSTRAINT duty_posts_duration_hours_check CHECK (((duration_hours > 0) AND (duration_hours <= 24))),
    CONSTRAINT duty_posts_recovery_sleep_days_check CHECK ((recovery_sleep_days >= 0)),
    CONSTRAINT duty_posts_required_weapon_kind_check CHECK ((required_weapon_kind = ANY (ARRAY['rifle'::text, 'pistol'::text]))),
    CONSTRAINT posts_own_schedule_complete CHECK (((start_time IS NULL) = (duration_hours IS NULL))),
    CONSTRAINT posts_per_day_needs_schedule CHECK (((NOT per_day) OR (start_time IS NOT NULL)))
);


--
-- Name: COLUMN duty_posts.start_time; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_posts.start_time IS 'Свой час заступления. NULL — пост замещается на весь период наряда';


--
-- Name: COLUMN duty_posts.per_day; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_posts.per_day IS 'Пост замещается на каждые сутки смены отдельно (ПТСО). Иначе — одним назначением на весь наряд, даже если у поста свои часы (ПУД)';


--
-- Name: COLUMN duty_posts.rotation_since; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_posts.rotation_since IS 'Сутки, с которых отсчитывается очередь подразделений на посту';


--
-- Name: COLUMN duty_posts.allow_consecutive; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_posts.allow_consecutive IS 'Заступление подряд: true — можно, false — нельзя, NULL — как у вида наряда';


--
-- Name: duty_posts_id_seq; Type: SEQUENCE; Schema: duty; Owner: -
--

CREATE SEQUENCE duty.duty_posts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: duty_posts_id_seq; Type: SEQUENCE OWNED BY; Schema: duty; Owner: -
--

ALTER SEQUENCE duty.duty_posts_id_seq OWNED BY duty.duty_posts.id;


--
-- Name: duty_type_permits; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.duty_type_permits (
    duty_type_id integer NOT NULL,
    permit_type_id integer NOT NULL
);


--
-- Name: duty_type_schedules; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.duty_type_schedules (
    id integer NOT NULL,
    duty_type_id integer NOT NULL,
    start_weekday integer NOT NULL,
    end_weekday integer NOT NULL,
    start_time time without time zone,
    CONSTRAINT schedules_weekday_range CHECK (((start_weekday >= 1) AND (start_weekday <= 7) AND ((end_weekday >= 1) AND (end_weekday <= 7))))
);


--
-- Name: TABLE duty_type_schedules; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON TABLE duty.duty_type_schedules IS 'Когда наряд положен: для смены — день заступления и день сдачи, для ежедневного — дни недели';


--
-- Name: duty_type_schedules_id_seq; Type: SEQUENCE; Schema: duty; Owner: -
--

CREATE SEQUENCE duty.duty_type_schedules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: duty_type_schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: duty; Owner: -
--

ALTER SEQUENCE duty.duty_type_schedules_id_seq OWNED BY duty.duty_type_schedules.id;


--
-- Name: duty_types; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.duty_types (
    id integer NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'daily'::text NOT NULL,
    start_time time without time zone,
    duration_hours integer,
    recovery_sleep_days integer DEFAULT 0 NOT NULL,
    recovery_off_days integer DEFAULT 0 NOT NULL,
    rest_excludes_weekends boolean DEFAULT false NOT NULL,
    base_weight numeric(6,2) DEFAULT 1.0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    allow_consecutive boolean DEFAULT false NOT NULL,
    holiday_rule text DEFAULT 'any'::text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    order_template jsonb,
    CONSTRAINT duty_types_holiday_rule_known CHECK ((holiday_rule = ANY (ARRAY['any'::text, 'only'::text, 'never'::text]))),
    CONSTRAINT duty_types_kind_known CHECK ((kind = ANY (ARRAY['daily'::text, 'multiday'::text]))),
    CONSTRAINT duty_types_rest_nonneg CHECK (((recovery_sleep_days >= 0) AND (recovery_off_days >= 0)))
);


--
-- Name: COLUMN duty_types.allow_consecutive; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_types.allow_consecutive IS 'Можно заступать в этот наряд подряд, не выждав отдыха от него же';


--
-- Name: COLUMN duty_types.holiday_rule; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON COLUMN duty.duty_types.holiday_rule IS 'Нерабочие дни: any — как обычно, only — наряд только в них, never — в них наряд не положен';


--
-- Name: duty_types_id_seq; Type: SEQUENCE; Schema: duty; Owner: -
--

CREATE SEQUENCE duty.duty_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: duty_types_id_seq; Type: SEQUENCE OWNED BY; Schema: duty; Owner: -
--

ALTER SEQUENCE duty.duty_types_id_seq OWNED BY duty.duty_types.id;


--
-- Name: order_template_versions; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.order_template_versions (
    id integer NOT NULL,
    duty_type_id integer NOT NULL,
    version integer NOT NULL,
    template jsonb,
    reason text NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT order_template_versions_reason_check CHECK ((length(TRIM(BOTH FROM reason)) > 0))
);


--
-- Name: order_template_versions_id_seq; Type: SEQUENCE; Schema: duty; Owner: -
--

CREATE SEQUENCE duty.order_template_versions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: order_template_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: duty; Owner: -
--

ALTER SEQUENCE duty.order_template_versions_id_seq OWNED BY duty.order_template_versions.id;


--
-- Name: post_employees; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.post_employees (
    post_id integer NOT NULL,
    employee_id integer NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by integer
);


--
-- Name: TABLE post_employees; Type: COMMENT; Schema: duty; Owner: -
--

COMMENT ON TABLE duty.post_employees IS 'Кто ходит на пост. Непустой перечень сужает кандидатов до перечисленных';


--
-- Name: post_rank_weights; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.post_rank_weights (
    post_id integer NOT NULL,
    rank_id integer NOT NULL,
    weight numeric NOT NULL
);


--
-- Name: post_responsibilities; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.post_responsibilities (
    post_id integer NOT NULL,
    on_date date NOT NULL,
    unit_id integer NOT NULL,
    note text,
    assigned_by integer,
    assigned_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: post_units; Type: TABLE; Schema: duty; Owner: -
--

CREATE TABLE duty.post_units (
    post_id integer NOT NULL,
    turn integer NOT NULL,
    unit_id integer NOT NULL,
    CONSTRAINT post_units_turn_check CHECK ((turn >= 1))
);


--
-- Name: v_assignment_periods; Type: VIEW; Schema: duty; Owner: -
--

CREATE VIEW duty.v_assignment_periods AS
 SELECT da.id,
    da.duty_id,
    da.employee_id,
    da.post_id,
    da.on_date,
    da.source,
    da.note,
    da.is_override,
    da.override_checks,
    d.duty_type_id,
    d.unit_id,
    d.status,
    dt.code AS duty_code,
        CASE
            WHEN (da.on_date IS NULL) THEN d.starts_at
            ELSE ((da.on_date + p.start_time))::timestamp with time zone
        END AS starts_at,
        CASE
            WHEN (da.on_date IS NULL) THEN d.ends_at
            ELSE (((da.on_date + p.start_time) + make_interval(hours => p.duration_hours)))::timestamp with time zone
        END AS ends_at,
    COALESCE(da.on_date, d.start_date) AS start_date,
    COALESCE(p.recovery_sleep_days, dt.recovery_sleep_days) AS recovery_sleep_days,
    COALESCE(p.allow_consecutive, dt.allow_consecutive) AS allow_consecutive,
        CASE
            WHEN (da.on_date IS NULL) THEN dt.rest_excludes_weekends
            ELSE false
        END AS rest_excludes_weekends,
        CASE
            WHEN (p.duration_hours IS NULL) THEN dt.base_weight
            WHEN (da.on_date IS NOT NULL) THEN round(((p.duration_hours)::numeric / 24.0), 2)
            ELSE round((((p.duration_hours)::numeric / 24.0) * GREATEST((1)::numeric, (EXTRACT(epoch FROM (d.ends_at - d.starts_at)) / (86400)::numeric))), 2)
        END AS base_weight
   FROM (((duty.duty_assignments da
     JOIN duty.duties d ON ((d.id = da.duty_id)))
     JOIN duty.duty_types dt ON ((dt.id = d.duty_type_id)))
     JOIN duty.duty_posts p ON ((p.id = da.post_id)));


--
-- Name: documents; Type: TABLE; Schema: parse; Owner: -
--

CREATE TABLE parse.documents (
    order_id integer NOT NULL,
    blocks jsonb,
    error text,
    extracted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: phrases; Type: TABLE; Schema: parse; Owner: -
--

CREATE TABLE parse.phrases (
    id integer NOT NULL,
    kind text NOT NULL,
    target text,
    phrase text NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    section_id integer NOT NULL,
    CONSTRAINT phrases_kind_check CHECK ((kind = ANY (ARRAY['order_permit'::text, 'order_absence'::text, 'permit'::text, 'absence'::text, 'mark_yes'::text]))),
    CONSTRAINT phrases_phrase_check CHECK ((length(TRIM(BOTH FROM phrase)) > 0))
);


--
-- Name: phrases_id_seq; Type: SEQUENCE; Schema: parse; Owner: -
--

CREATE SEQUENCE parse.phrases_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: phrases_id_seq; Type: SEQUENCE OWNED BY; Schema: parse; Owner: -
--

ALTER SEQUENCE parse.phrases_id_seq OWNED BY parse.phrases.id;


--
-- Name: profiles; Type: TABLE; Schema: parse; Owner: -
--

CREATE TABLE parse.profiles (
    id integer NOT NULL,
    name text NOT NULL,
    header_phrases text[] DEFAULT '{}'::text[] NOT NULL,
    absence_code text,
    permit_type_id integer,
    reserve_weapons boolean DEFAULT false NOT NULL,
    default_days integer,
    is_active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT profiles_default_days_check CHECK (((default_days IS NULL) OR ((default_days >= 1) AND (default_days <= 366)))),
    CONSTRAINT profiles_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


--
-- Name: profiles_id_seq; Type: SEQUENCE; Schema: parse; Owner: -
--

CREATE SEQUENCE parse.profiles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: parse; Owner: -
--

ALTER SEQUENCE parse.profiles_id_seq OWNED BY parse.profiles.id;


--
-- Name: sections; Type: TABLE; Schema: parse; Owner: -
--

CREATE TABLE parse.sections (
    id integer NOT NULL,
    name text NOT NULL,
    kind text NOT NULL,
    builtin boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sections_kind_check CHECK ((kind = ANY (ARRAY['order_permit'::text, 'order_absence'::text, 'permit'::text, 'absence'::text, 'mark_yes'::text]))),
    CONSTRAINT sections_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0))
);


--
-- Name: sections_id_seq; Type: SEQUENCE; Schema: parse; Owner: -
--

CREATE SEQUENCE parse.sections_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sections_id_seq; Type: SEQUENCE OWNED BY; Schema: parse; Owner: -
--

ALTER SEQUENCE parse.sections_id_seq OWNED BY parse.sections.id;


--
-- Name: absence_types; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.absence_types (
    id integer NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    blocks_duty boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: absence_types_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.absence_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: absence_types_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.absence_types_id_seq OWNED BY personnel.absence_types.id;


--
-- Name: absences; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.absences (
    id integer NOT NULL,
    employee_id integer NOT NULL,
    absence_type_id integer NOT NULL,
    date_from date NOT NULL,
    date_to date NOT NULL,
    document_ref text,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by integer,
    source text DEFAULT 'manual'::text NOT NULL,
    cancelled_at timestamp with time zone,
    cancelled_by integer,
    order_id integer,
    CONSTRAINT absences_dates_ordered CHECK ((date_to >= date_from)),
    CONSTRAINT absences_source_known CHECK ((source = ANY (ARRAY['manual'::text, 'import'::text])))
);


--
-- Name: COLUMN absences.created_by; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON COLUMN personnel.absences.created_by IS 'Кто внес запись. Заполняется при вводе через интерфейс; у данных, загруженных из приказов (МС-3), остается пустым.';


--
-- Name: COLUMN absences.source; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON COLUMN personnel.absences.source IS 'Происхождение записи: manual — внесена человеком, import — разобрана из приказа (МС-3)';


--
-- Name: COLUMN absences.cancelled_at; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON COLUMN personnel.absences.cancelled_at IS 'Момент снятия записи; снятая запись в расчет наличия не входит, но сохраняется';


--
-- Name: absences_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.absences_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: absences_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.absences_id_seq OWNED BY personnel.absences.id;


--
-- Name: employee_permits_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.employee_permits_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: employee_permits_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.employee_permits_id_seq OWNED BY personnel.employee_permits.id;


--
-- Name: employee_post_weights; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.employee_post_weights (
    employee_id integer NOT NULL,
    post_id integer NOT NULL,
    weight numeric NOT NULL,
    note text,
    updated_by integer,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: employees; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.employees (
    id integer NOT NULL,
    last_name text NOT NULL,
    first_name text NOT NULL,
    middle_name text,
    rank_id integer,
    "position" text,
    unit_id integer,
    personnel_number text,
    phone text,
    email text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    excluded_on date,
    exclusion_reason text
);


--
-- Name: employees_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.employees_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: employees_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.employees_id_seq OWNED BY personnel.employees.id;


--
-- Name: permit_directions; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.permit_directions (
    id integer NOT NULL,
    parent_id integer,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT permit_directions_name_not_empty CHECK ((btrim(name) <> ''::text))
);


--
-- Name: TABLE permit_directions; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON TABLE personnel.permit_directions IS 'Направления допуска: дерево каталогов, в которых лежат приказы';


--
-- Name: permit_directions_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.permit_directions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: permit_directions_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.permit_directions_id_seq OWNED BY personnel.permit_directions.id;


--
-- Name: permit_orders; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.permit_orders (
    id integer NOT NULL,
    number text NOT NULL,
    issued_on date NOT NULL,
    title text,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    direction_id integer,
    file_name text,
    file_path text,
    file_mime text,
    file_size integer,
    pdf_path text,
    pdf_error text,
    source text DEFAULT 'manual'::text NOT NULL,
    parsed_at timestamp with time zone,
    created_by integer,
    kind text DEFAULT 'permit'::text NOT NULL,
    profile_id integer,
    CONSTRAINT permit_orders_direction_by_kind CHECK (((kind = 'permit'::text) = (direction_id IS NOT NULL))),
    CONSTRAINT permit_orders_kind_check CHECK ((kind = ANY (ARRAY['permit'::text, 'absence'::text, 'other'::text]))),
    CONSTRAINT permit_orders_profile_by_kind CHECK (((kind = 'other'::text) = (profile_id IS NOT NULL))),
    CONSTRAINT permit_orders_source_known CHECK ((source = ANY (ARRAY['manual'::text, 'import'::text])))
);


--
-- Name: COLUMN permit_orders.pdf_path; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON COLUMN personnel.permit_orders.pdf_path IS 'Приказ для чтения: PDF. Для DOC/DOCX получен пересохранением, для PDF — он сам';


--
-- Name: COLUMN permit_orders.pdf_error; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON COLUMN personnel.permit_orders.pdf_error IS 'Почему PDF не построен: показывается вместо приказа, чтобы отказ не выглядел пустой страницей';


--
-- Name: permit_orders_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.permit_orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: permit_orders_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.permit_orders_id_seq OWNED BY personnel.permit_orders.id;


--
-- Name: permit_types; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.permit_types (
    id integer NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    default_validity_months integer,
    is_post_specific boolean DEFAULT false NOT NULL,
    notify_days_before integer DEFAULT 30 NOT NULL,
    is_active boolean DEFAULT true NOT NULL
);


--
-- Name: permit_types_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.permit_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: permit_types_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.permit_types_id_seq OWNED BY personnel.permit_types.id;


--
-- Name: v_valid_permits; Type: VIEW; Schema: personnel; Owner: -
--

CREATE VIEW personnel.v_valid_permits AS
 SELECT id,
    employee_id,
    permit_type_id,
    post_id,
    issued_at,
    expires_at
   FROM personnel.employee_permits p
  WHERE personnel.permit_is_valid(p.*, CURRENT_DATE);


--
-- Name: VIEW v_valid_permits; Type: COMMENT; Schema: personnel; Owner: -
--

COMMENT ON VIEW personnel.v_valid_permits IS 'Допуски, действующие СЕГОДНЯ. Для проверки на дату заступления используется personnel.permit_is_valid(p, дата).';


--
-- Name: v_weapon_loans; Type: VIEW; Schema: personnel; Owner: -
--

CREATE VIEW personnel.v_weapon_loans AS
 SELECT a.id,
    da.weapon_id,
    a.employee_id,
    a.duty_id,
    a.post_id,
    a.starts_at,
    a.ends_at,
    ('на время наряда: '::text || p.name) AS reason
   FROM ((duty.v_assignment_periods a
     JOIN duty.duty_assignments da ON ((da.id = a.id)))
     JOIN duty.duty_posts p ON ((p.id = a.post_id)))
  WHERE ((da.weapon_id IS NOT NULL) AND (a.status <> 'cancelled'::text));


--
-- Name: weapons; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.weapons (
    id integer NOT NULL,
    name text NOT NULL,
    serial_number text NOT NULL,
    manufactured_on date NOT NULL,
    kind text NOT NULL,
    owner_id integer,
    is_active boolean DEFAULT true NOT NULL,
    unit_id integer,
    sort_order integer DEFAULT 0 NOT NULL,
    CONSTRAINT weapons_kind_check CHECK ((kind = ANY (ARRAY['rifle'::text, 'pistol'::text]))),
    CONSTRAINT weapons_name_check CHECK ((length(TRIM(BOTH FROM name)) > 0)),
    CONSTRAINT weapons_serial_number_check CHECK ((length(TRIM(BOTH FROM serial_number)) > 0))
);


--
-- Name: v_weapons; Type: VIEW; Schema: personnel; Owner: -
--

CREATE VIEW personnel.v_weapons AS
 SELECT w.id,
    w.name,
    w.serial_number,
    w.manufactured_on,
    w.kind,
    w.owner_id,
    w.is_active,
    w.unit_id,
    w.sort_order,
    COALESCE(w.owner_id, u.commander_employee_id) AS holder_id
   FROM (personnel.weapons w
     LEFT JOIN core.units u ON ((u.id = w.unit_id)));


--
-- Name: weapon_reservations; Type: TABLE; Schema: personnel; Owner: -
--

CREATE TABLE personnel.weapon_reservations (
    id integer NOT NULL,
    weapon_id integer NOT NULL,
    employee_id integer,
    date_from date NOT NULL,
    date_to date NOT NULL,
    reason text,
    order_id integer,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    cancelled_at timestamp with time zone,
    CONSTRAINT weapon_reservations_check CHECK ((date_to >= date_from))
);


--
-- Name: weapon_reservations_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.weapon_reservations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: weapon_reservations_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.weapon_reservations_id_seq OWNED BY personnel.weapon_reservations.id;


--
-- Name: weapons_id_seq; Type: SEQUENCE; Schema: personnel; Owner: -
--

CREATE SEQUENCE personnel.weapons_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: weapons_id_seq; Type: SEQUENCE OWNED BY; Schema: personnel; Owner: -
--

ALTER SEQUENCE personnel.weapons_id_seq OWNED BY personnel.weapons.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    name text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: change_log id; Type: DEFAULT; Schema: audit; Owner: -
--

ALTER TABLE ONLY audit.change_log ALTER COLUMN id SET DEFAULT nextval('audit.change_log_id_seq'::regclass);


--
-- Name: changes id; Type: DEFAULT; Schema: audit; Owner: -
--

ALTER TABLE ONLY audit.changes ALTER COLUMN id SET DEFAULT nextval('audit.changes_id_seq'::regclass);


--
-- Name: acting_commanders id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.acting_commanders ALTER COLUMN id SET DEFAULT nextval('core.acting_commanders_id_seq'::regclass);


--
-- Name: positions id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.positions ALTER COLUMN id SET DEFAULT nextval('core.positions_id_seq'::regclass);


--
-- Name: ranks id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.ranks ALTER COLUMN id SET DEFAULT nextval('core.ranks_id_seq'::regclass);


--
-- Name: security_events id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.security_events ALTER COLUMN id SET DEFAULT nextval('core.security_events_id_seq'::regclass);


--
-- Name: units id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.units ALTER COLUMN id SET DEFAULT nextval('core.units_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users ALTER COLUMN id SET DEFAULT nextval('core.users_id_seq'::regclass);


--
-- Name: duties id; Type: DEFAULT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties ALTER COLUMN id SET DEFAULT nextval('duty.duties_id_seq'::regclass);


--
-- Name: duty_assignments id; Type: DEFAULT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments ALTER COLUMN id SET DEFAULT nextval('duty.duty_assignments_id_seq'::regclass);


--
-- Name: duty_posts id; Type: DEFAULT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_posts ALTER COLUMN id SET DEFAULT nextval('duty.duty_posts_id_seq'::regclass);


--
-- Name: duty_type_schedules id; Type: DEFAULT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_type_schedules ALTER COLUMN id SET DEFAULT nextval('duty.duty_type_schedules_id_seq'::regclass);


--
-- Name: duty_types id; Type: DEFAULT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_types ALTER COLUMN id SET DEFAULT nextval('duty.duty_types_id_seq'::regclass);


--
-- Name: order_template_versions id; Type: DEFAULT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.order_template_versions ALTER COLUMN id SET DEFAULT nextval('duty.order_template_versions_id_seq'::regclass);


--
-- Name: phrases id; Type: DEFAULT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.phrases ALTER COLUMN id SET DEFAULT nextval('parse.phrases_id_seq'::regclass);


--
-- Name: profiles id; Type: DEFAULT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.profiles ALTER COLUMN id SET DEFAULT nextval('parse.profiles_id_seq'::regclass);


--
-- Name: sections id; Type: DEFAULT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.sections ALTER COLUMN id SET DEFAULT nextval('parse.sections_id_seq'::regclass);


--
-- Name: absence_types id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absence_types ALTER COLUMN id SET DEFAULT nextval('personnel.absence_types_id_seq'::regclass);


--
-- Name: absences id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences ALTER COLUMN id SET DEFAULT nextval('personnel.absences_id_seq'::regclass);


--
-- Name: employee_permits id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_permits ALTER COLUMN id SET DEFAULT nextval('personnel.employee_permits_id_seq'::regclass);


--
-- Name: employees id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employees ALTER COLUMN id SET DEFAULT nextval('personnel.employees_id_seq'::regclass);


--
-- Name: permit_directions id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_directions ALTER COLUMN id SET DEFAULT nextval('personnel.permit_directions_id_seq'::regclass);


--
-- Name: permit_orders id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_orders ALTER COLUMN id SET DEFAULT nextval('personnel.permit_orders_id_seq'::regclass);


--
-- Name: permit_types id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_types ALTER COLUMN id SET DEFAULT nextval('personnel.permit_types_id_seq'::regclass);


--
-- Name: weapon_reservations id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapon_reservations ALTER COLUMN id SET DEFAULT nextval('personnel.weapon_reservations_id_seq'::regclass);


--
-- Name: weapons id; Type: DEFAULT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapons ALTER COLUMN id SET DEFAULT nextval('personnel.weapons_id_seq'::regclass);


--
-- Data for Name: change_log; Type: TABLE DATA; Schema: audit; Owner: -
--

COPY audit.change_log (id, schema_name, table_name, record_id, action, source, document_ref, changed_by, changed_at, old_values, new_values) FROM stdin;
\.


--
-- Data for Name: acting_commanders; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.acting_commanders (id, unit_id, employee_id, date_from, date_to, reason, created_by, created_at, cancelled_at) FROM stdin;
\.


--
-- Data for Name: calendar_days; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.calendar_days (day, name, kind, created_at, updated_at) FROM stdin;
2026-01-01	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-02	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-03	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-04	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-05	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-06	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-07	Рождество Христово	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-01-08	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-02-23	День защитника Отечества	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-03-08	Международный женский день	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-05-09	День Победы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-06-12	День России	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-11-04	День народного единства	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-01	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-02	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-03	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-04	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-05	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-06	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-07	Рождество Христово	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-01-08	Новогодние каникулы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-02-23	День защитника Отечества	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-03-08	Международный женский день	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-05-01	Праздник Весны и Труда	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-05-09	День Победы	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-06-12	День России	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2027-11-04	День народного единства	holiday	2026-09-07 14:06:03.431417+07	2026-09-07 14:06:03.431417+07
2026-05-01	Праздник Весны и Труда	holiday	2026-09-07 15:46:15.387268+07	2026-09-07 15:46:15.387268+07
2026-09-09	Осенние каникулы	holiday	2026-09-07 15:48:52.161288+07	2026-09-07 15:48:52.161288+07
2026-09-10	Осенние каникулы	holiday	2026-09-07 15:48:52.161288+07	2026-09-07 15:48:52.161288+07
2026-09-11	Осенние каникулы	holiday	2026-09-07 15:48:52.161288+07	2026-09-07 15:48:52.161288+07
2026-09-12	Осенние каникулы	holiday	2026-09-07 15:48:52.161288+07	2026-09-07 15:48:52.161288+07
2026-09-13	Осенние каникулы	holiday	2026-09-07 15:48:52.161288+07	2026-09-07 15:48:52.161288+07
\.


--
-- Data for Name: permissions; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.permissions (code, name, section, sort_order) FROM stdin;
duty.view	Просмотр графика и нарядов	Наряды	10
duty.create	Назначение и правка состава	Наряды	20
duty.approve	Утверждение приказа	Наряды	30
duty.withdraw	Снятие человека с наряда	Наряды	40
duty.override	Назначение вопреки правилам отбора	Наряды	50
post.manage	Справочник постов	Справочники	60
calendar.manage	Празднично-выходные дни	Справочники	70
personnel.view	Просмотр личного состава	Личный состав	80
weapon.view	Просмотр учета оружия	Оружие	90
user.manage	Учетные записи и права доступа	Управление	110
unit.manage	Структура подразделений	Личный состав	75
personnel.assign	Распределение личного состава	Личный состав	76
duty.responsibility	Закрепление подразделения за нарядом	Наряды	35
queue.manage	Настройка весов и подбора	Управление	115
absence.manage	Ввод отсутствий личного состава	Личный состав	85
dutytype.manage	Справочник видов нарядов	Справочники	55
permit.manage	Приказы на допуск и допуски личного состава	Личный состав	86
staff.manage	Штат: должности и перевод любого сотрудника	Личный состав	55
weapon.transfer	Оружие: полный доступ (заведение, списание, склад, любые подразделения)	Оружие	100
weapon.assign	Оружие: закрепление и перемещение в своем подразделении	Оружие	95
audit.view	Просмотр журнала изменений	Управление	210
\.


--
-- Data for Name: positions; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.positions (id, unit_id, title, sort_order, employee_id, created_at, is_commander) FROM stdin;
2	2	старший техник	20	21	2026-09-27 13:37:27.802592+07	f
4	3	оператор	20	20	2026-09-27 13:37:27.802592+07	f
5	4	начальник службы	10	149	2026-09-27 13:37:27.802592+07	f
7	4	начальник службы	30	140	2026-09-27 13:37:27.802592+07	f
8	4	механик	40	34	2026-09-27 13:37:27.802592+07	f
9	4	механик	50	10	2026-09-27 13:37:27.802592+07	f
10	4	начальник службы	60	137	2026-09-27 13:37:27.802592+07	f
11	4	командир отделения	70	22	2026-09-27 13:37:27.802592+07	f
12	4	начальник службы	80	143	2026-09-27 13:37:27.802592+07	f
13	4	командир взвода	90	130	2026-09-27 13:37:27.802592+07	f
14	4	командир взвода	100	134	2026-09-27 13:37:27.802592+07	f
15	4	командир взвода	110	136	2026-09-27 13:37:27.802592+07	f
16	4	командир взвода	120	132	2026-09-27 13:37:27.802592+07	f
17	4	командир взвода	130	128	2026-09-27 13:37:27.802592+07	f
18	4	командир взвода	140	120	2026-09-27 13:37:27.802592+07	f
19	4	командир взвода	150	124	2026-09-27 13:37:27.802592+07	f
20	4	командир взвода	160	126	2026-09-27 13:37:27.802592+07	f
21	4	командир взвода	170	122	2026-09-27 13:37:27.802592+07	f
22	4	командир взвода	180	110	2026-09-27 13:37:27.802592+07	f
23	4	командир взвода	190	114	2026-09-27 13:37:27.802592+07	f
24	4	командир взвода	200	116	2026-09-27 13:37:27.802592+07	f
25	4	командир взвода	210	112	2026-09-27 13:37:27.802592+07	f
26	4	командир взвода	220	118	2026-09-27 13:37:27.802592+07	f
27	4	техник	230	100	2026-09-27 13:37:27.802592+07	f
28	4	техник	240	104	2026-09-27 13:37:27.802592+07	f
29	4	техник	250	106	2026-09-27 13:37:27.802592+07	f
30	4	техник	260	102	2026-09-27 13:37:27.802592+07	f
31	4	техник	270	108	2026-09-27 13:37:27.802592+07	f
32	4	техник	280	94	2026-09-27 13:37:27.802592+07	f
33	4	техник	290	96	2026-09-27 13:37:27.802592+07	f
34	4	техник	300	98	2026-09-27 13:37:27.802592+07	f
35	4	командир отделения	310	30	2026-09-27 13:37:27.802592+07	f
36	4	командир отделения	320	6	2026-09-27 13:37:27.802592+07	f
37	4	механик	330	18	2026-09-27 13:37:27.802592+07	f
38	4	механик	340	2	2026-09-27 13:37:27.802592+07	f
39	4	командир отделения	350	38	2026-09-27 13:37:27.802592+07	f
40	4	командир отделения	360	14	2026-09-27 13:37:27.802592+07	f
41	4	механик	370	26	2026-09-27 13:37:27.802592+07	f
42	5	начальник службы	10	150	2026-09-27 13:37:27.802592+07	f
43	5	начальник службы	20	144	2026-09-27 13:37:27.802592+07	f
44	5	радиотелефонист	30	35	2026-09-27 13:37:27.802592+07	f
46	5	начальник службы	50	147	2026-09-27 13:37:27.802592+07	f
47	5	заместитель командира взвода	60	23	2026-09-27 13:37:27.802592+07	f
48	5	начальник службы	70	141	2026-09-27 13:37:27.802592+07	f
49	5	начальник службы	80	138	2026-09-27 13:37:27.802592+07	f
50	5	командир взвода	90	135	2026-09-27 13:37:27.802592+07	f
51	5	командир взвода	100	129	2026-09-27 13:37:27.802592+07	f
52	5	командир взвода	110	131	2026-09-27 13:37:27.802592+07	f
53	5	командир взвода	120	127	2026-09-27 13:37:27.802592+07	f
54	5	командир взвода	130	133	2026-09-27 13:37:27.802592+07	f
55	5	командир взвода	140	125	2026-09-27 13:37:27.802592+07	f
56	5	командир взвода	150	121	2026-09-27 13:37:27.802592+07	f
57	5	командир взвода	160	123	2026-09-27 13:37:27.802592+07	f
58	5	командир взвода	170	115	2026-09-27 13:37:27.802592+07	f
59	5	командир взвода	180	119	2026-09-27 13:37:27.802592+07	f
60	5	командир взвода	190	111	2026-09-27 13:37:27.802592+07	f
61	5	командир взвода	200	117	2026-09-27 13:37:27.802592+07	f
62	5	командир взвода	210	113	2026-09-27 13:37:27.802592+07	f
63	5	техник	220	105	2026-09-27 13:37:27.802592+07	f
64	5	техник	230	109	2026-09-27 13:37:27.802592+07	f
65	5	техник	240	101	2026-09-27 13:37:27.802592+07	f
66	5	техник	250	107	2026-09-27 13:37:27.802592+07	f
67	5	техник	260	103	2026-09-27 13:37:27.802592+07	f
68	5	техник	270	95	2026-09-27 13:37:27.802592+07	f
69	5	техник	280	99	2026-09-27 13:37:27.802592+07	f
70	5	техник	290	97	2026-09-27 13:37:27.802592+07	f
71	5	техник	300	93	2026-09-27 13:37:27.802592+07	f
72	5	заместитель командира взвода	310	31	2026-09-27 13:37:27.802592+07	f
73	5	заместитель командира взвода	320	7	2026-09-27 13:37:27.802592+07	f
74	5	радиотелефонист	330	19	2026-09-27 13:37:27.802592+07	f
75	5	радиотелефонист	340	3	2026-09-27 13:37:27.802592+07	f
76	5	заместитель командира взвода	350	39	2026-09-27 13:37:27.802592+07	f
77	5	заместитель командира взвода	360	15	2026-09-27 13:37:27.802592+07	f
78	5	радиотелефонист	370	27	2026-09-27 13:37:27.802592+07	f
149	33	заместитель командира части	30	164	2026-09-27 13:37:27.802592+07	f
150	33	заместитель командира части	40	169	2026-09-27 13:37:27.802592+07	f
151	33	заместитель командира части	50	161	2026-09-27 13:37:27.802592+07	f
152	33	заместитель командира части	60	166	2026-09-27 13:37:27.802592+07	f
153	33	заместитель командира части	70	162	2026-09-27 13:37:27.802592+07	f
154	33	заместитель командира части	80	167	2026-09-27 13:37:27.802592+07	f
155	33	заместитель командира части	90	163	2026-09-27 13:37:27.802592+07	f
156	33	заместитель командира части	100	168	2026-09-27 13:37:27.802592+07	f
157	33	заместитель командира части	110	155	2026-09-27 13:37:27.802592+07	f
158	33	заместитель командира части	120	160	2026-09-27 13:37:27.802592+07	f
159	33	заместитель командира части	130	154	2026-09-27 13:37:27.802592+07	f
160	33	заместитель командира части	140	159	2026-09-27 13:37:27.802592+07	f
161	33	заместитель командира части	150	151	2026-09-27 13:37:27.802592+07	f
162	33	заместитель командира части	160	156	2026-09-27 13:37:27.802592+07	f
163	33	заместитель командира части	170	152	2026-09-27 13:37:27.802592+07	f
164	33	заместитель командира части	180	157	2026-09-27 13:37:27.802592+07	f
165	33	заместитель командира части	190	153	2026-09-27 13:37:27.802592+07	f
166	33	заместитель командира части	200	158	2026-09-27 13:37:27.802592+07	f
167	33	начальник службы	210	145	2026-09-27 13:37:27.802592+07	f
168	33	начальник службы	220	148	2026-09-27 13:37:27.802592+07	f
169	33	начальник службы	230	139	2026-09-27 13:37:27.802592+07	f
171	20	Командир отделения	10	72	2026-09-27 13:59:22.24411+07	t
172	20	Заместитель командира отделения	20	62	2026-09-27 13:59:22.24411+07	f
173	20	Наводчик-оператор	30	44	2026-09-27 13:59:22.24411+07	f
174	20	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
175	20	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
176	20	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
177	20	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
178	20	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
179	25	Командир отделения	10	85	2026-09-27 13:59:22.24411+07	t
180	25	Заместитель командира отделения	20	55	2026-09-27 13:59:22.24411+07	f
181	25	Наводчик-оператор	30	24	2026-09-27 13:59:22.24411+07	f
182	25	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
183	25	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
184	25	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
185	25	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
186	25	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
187	26	Командир отделения	10	73	2026-09-27 13:59:22.24411+07	t
188	26	Заместитель командира отделения	20	57	2026-09-27 13:59:22.24411+07	f
189	26	Наводчик-оператор	30	36	2026-09-27 13:59:22.24411+07	f
190	26	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
191	26	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
192	26	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
147	33	заместитель командира части	10	170	2026-09-27 13:37:27.802592+07	t
148	33	заместитель командира части	20	\N	2026-09-27 13:37:27.802592+07	f
170	33	начальник службы	240	142	2026-09-27 13:37:27.802592+07	f
193	26	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
194	26	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
195	27	Командир отделения	10	75	2026-09-27 13:59:22.24411+07	t
196	27	Заместитель командира отделения	20	59	2026-09-27 13:59:22.24411+07	f
197	27	Наводчик-оператор	30	41	2026-09-27 13:59:22.24411+07	f
198	27	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
199	27	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
200	27	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
201	27	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
202	27	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
203	17	Командир отделения	10	5	2026-09-27 13:59:22.24411+07	t
204	17	Заместитель командира отделения	20	56	2026-09-27 13:59:22.24411+07	f
205	17	Наводчик-оператор	30	25	2026-09-27 13:59:22.24411+07	f
206	17	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
207	17	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
208	17	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
209	17	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
210	17	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
211	12	Командир отделения	10	90	2026-09-27 13:59:22.24411+07	t
212	12	Заместитель командира отделения	20	74	2026-09-27 13:59:22.24411+07	f
213	12	Наводчик-оператор	30	64	2026-09-27 13:59:22.24411+07	f
214	12	Механик-водитель	40	46	2026-09-27 13:59:22.24411+07	f
215	12	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
216	12	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
217	12	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
218	12	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
219	18	Командир отделения	10	17	2026-09-27 13:59:22.24411+07	t
220	18	Заместитель командира отделения	20	58	2026-09-27 13:59:22.24411+07	f
221	18	Наводчик-оператор	30	37	2026-09-27 13:59:22.24411+07	f
222	18	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
223	18	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
224	18	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
225	18	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
226	18	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
227	15	Командир отделения	10	82	2026-09-27 13:59:22.24411+07	t
228	15	Заместитель командира отделения	20	70	2026-09-27 13:59:22.24411+07	f
229	15	Наводчик-оператор	30	1	2026-09-27 13:59:22.24411+07	f
230	15	Механик-водитель	40	52	2026-09-27 13:59:22.24411+07	f
231	15	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
232	15	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
233	15	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
234	15	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
235	13	Командир отделения	10	92	2026-09-27 13:59:22.24411+07	t
236	13	Заместитель командира отделения	20	76	2026-09-27 13:59:22.24411+07	f
237	13	Наводчик-оператор	30	66	2026-09-27 13:59:22.24411+07	f
238	13	Механик-водитель	40	48	2026-09-27 13:59:22.24411+07	f
239	13	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
240	13	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
241	13	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
242	13	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
243	21	Командир отделения	10	91	2026-09-27 13:59:22.24411+07	t
244	21	Заместитель командира отделения	20	16	2026-09-27 13:59:22.24411+07	f
245	21	Наводчик-оператор	30	65	2026-09-27 13:59:22.24411+07	f
246	21	Механик-водитель	40	47	2026-09-27 13:59:22.24411+07	f
247	21	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
248	21	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
249	21	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
250	21	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
251	19	Командир отделения	10	29	2026-09-27 13:59:22.24411+07	t
252	19	Заместитель командира отделения	20	60	2026-09-27 13:59:22.24411+07	f
253	19	Наводчик-оператор	30	42	2026-09-27 13:59:22.24411+07	f
254	19	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
255	19	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
256	19	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
257	19	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
258	19	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
259	24	Командир отделения	10	83	2026-09-27 13:59:22.24411+07	t
260	24	Заместитель командира отделения	20	71	2026-09-27 13:59:22.24411+07	f
261	24	Наводчик-оператор	30	12	2026-09-27 13:59:22.24411+07	f
262	24	Механик-водитель	40	53	2026-09-27 13:59:22.24411+07	f
263	24	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
264	24	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
265	24	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
266	24	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
267	28	Командир отделения	10	77	2026-09-27 13:59:22.24411+07	t
268	28	Заместитель командира отделения	20	61	2026-09-27 13:59:22.24411+07	f
269	28	Наводчик-оператор	30	43	2026-09-27 13:59:22.24411+07	f
270	28	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
271	28	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
272	28	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
273	28	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
274	28	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
275	29	Командир отделения	10	4	2026-09-27 13:59:22.24411+07	t
276	29	Заместитель командира отделения	20	63	2026-09-27 13:59:22.24411+07	f
277	29	Наводчик-оператор	30	45	2026-09-27 13:59:22.24411+07	f
278	29	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
279	29	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
280	29	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
281	29	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
282	29	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
283	16	Командир отделения	10	84	2026-09-27 13:59:22.24411+07	t
284	16	Заместитель командира отделения	20	54	2026-09-27 13:59:22.24411+07	f
285	16	Наводчик-оператор	30	13	2026-09-27 13:59:22.24411+07	f
286	16	Механик-водитель	40	\N	2026-09-27 13:59:22.24411+07	f
287	16	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
288	16	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
289	16	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
290	16	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
291	23	Командир отделения	10	81	2026-09-27 13:59:22.24411+07	t
292	23	Заместитель командира отделения	20	40	2026-09-27 13:59:22.24411+07	f
293	23	Наводчик-оператор	30	69	2026-09-27 13:59:22.24411+07	f
294	23	Механик-водитель	40	51	2026-09-27 13:59:22.24411+07	f
295	23	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
296	23	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
297	23	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
298	23	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
299	22	Командир отделения	10	79	2026-09-27 13:59:22.24411+07	t
300	22	Заместитель командира отделения	20	28	2026-09-27 13:59:22.24411+07	f
301	22	Наводчик-оператор	30	67	2026-09-27 13:59:22.24411+07	f
302	22	Механик-водитель	40	49	2026-09-27 13:59:22.24411+07	f
303	22	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
304	22	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
305	22	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
306	22	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
307	14	Командир отделения	10	80	2026-09-27 13:59:22.24411+07	t
308	14	Заместитель командира отделения	20	78	2026-09-27 13:59:22.24411+07	f
309	14	Наводчик-оператор	30	68	2026-09-27 13:59:22.24411+07	f
310	14	Механик-водитель	40	50	2026-09-27 13:59:22.24411+07	f
311	14	Пулемётчик	50	\N	2026-09-27 13:59:22.24411+07	f
312	14	Гранатомётчик	60	\N	2026-09-27 13:59:22.24411+07	f
313	14	Старший стрелок	70	\N	2026-09-27 13:59:22.24411+07	f
314	14	Стрелок	80	\N	2026-09-27 13:59:22.24411+07	f
1	2	водитель	10	9	2026-09-27 13:37:27.802592+07	t
3	3	стрелок	10	8	2026-09-27 13:37:27.802592+07	t
6	4	начальник службы	20	146	2026-09-27 13:37:27.802592+07	t
45	5	радиотелефонист	40	11	2026-09-27 13:37:27.802592+07	t
79	6	водитель	10	33	2026-09-27 13:37:27.802592+07	t
80	7	командир отделения	10	86	2026-09-27 13:37:27.802592+07	t
81	8	командир отделения	10	88	2026-09-27 13:37:27.802592+07	t
82	9	стрелок	10	32	2026-09-27 13:37:27.802592+07	t
83	10	командир отделения	10	87	2026-09-27 13:37:27.802592+07	t
84	11	командир отделения	10	89	2026-09-27 13:37:27.802592+07	t
317	49	Командир подразделения	10	\N	2026-09-27 14:33:34.570787+07	t
315	1	Командир части	10	165	2026-09-27 14:02:42.370999+07	t
318	50	Начальник штаба	10	171	2026-09-27 14:49:18.755948+07	t
319	50	Заместитель начальника штаба	20	172	2026-09-27 14:49:18.755948+07	f
320	50	Помощник начальника штаба	30	\N	2026-09-27 14:49:18.755948+07	f
321	50	Делопроизводитель	40	173	2026-09-27 14:49:18.755948+07	f
322	50	Писарь	50	\N	2026-09-27 14:49:18.755948+07	f
\.


--
-- Data for Name: ranks; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.ranks (id, name, short_name, seniority, is_active) FROM stdin;
1	рядовой	р-й	10	t
2	ефрейтор	ефр.	20	t
3	младший сержант	мл. с-т	30	t
4	сержант	с-т	40	t
5	старший сержант	ст. с-т	50	t
6	старшина	ст-на	60	t
7	прапорщик	пр-к	70	t
8	старший прапорщик	ст. пр-к	80	t
9	младший лейтенант	мл. л-т	90	t
10	лейтенант	л-т	100	t
11	старший лейтенант	ст. л-т	110	t
12	капитан	к-н	120	t
13	майор	м-р	130	t
14	подполковник	п/п-к	140	t
15	полковник	п-к	150	t
\.


--
-- Data for Name: role_permissions; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.role_permissions (role_code, permission_code) FROM stdin;
admin	duty.view
admin	duty.create
admin	duty.approve
admin	duty.withdraw
admin	duty.override
admin	post.manage
admin	calendar.manage
admin	personnel.view
admin	weapon.view
admin	weapon.transfer
admin	user.manage
deputy	duty.view
deputy	duty.create
deputy	duty.approve
deputy	duty.withdraw
deputy	post.manage
deputy	calendar.manage
deputy	personnel.view
deputy	weapon.view
chief	duty.view
chief	duty.create
chief	duty.approve
chief	duty.withdraw
chief	personnel.view
chief	weapon.view
commander	duty.view
commander	duty.create
commander	personnel.view
commander	weapon.view
user	duty.view
admin	unit.manage
admin	personnel.assign
admin	duty.responsibility
deputy	unit.manage
deputy	personnel.assign
deputy	duty.responsibility
chief	duty.responsibility
commander	unit.manage
commander	personnel.assign
admin	queue.manage
deputy	queue.manage
admin	absence.manage
deputy	absence.manage
chief	absence.manage
commander	absence.manage
admin	dutytype.manage
deputy	dutytype.manage
admin	permit.manage
deputy	permit.manage
chief	permit.manage
admin	staff.manage
hr	staff.manage
hr	personnel.assign
hr	personnel.view
hr	unit.manage
hr	duty.view
admin	weapon.assign
commander	weapon.assign
armament	weapon.view
armament	weapon.transfer
armament	weapon.assign
armament	personnel.view
armament	duty.view
admin	audit.view
\.


--
-- Data for Name: roles; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.roles (code, name, level, is_system) FROM stdin;
admin	Администратор системы	1	t
deputy	Заместитель	2	t
chief	Начальник службы	3	t
commander	Командир подразделения	4	t
user	Пользователь	5	t
hr	Кадровик	3	t
armament	Начальник службы вооружения	3	t
\.


--
-- Data for Name: settings; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.settings (key, value, name, description, updated_by, updated_at) FROM stdin;
queue.min_days_off	1	Наименьший простой после сдачи, суток	Сколько суток после сдачи последнего наряда должно пройти, чтобы человек снова предлагался. 1 — нельзя только в сутки сдачи, со следующих можно; 2 — еще сутки паузы. Это порог: не прошедший его в списке не показывается. Где разрешено заступление подряд, порог не действует.	\N	2026-09-19 15:01:09.869389+07
queue.ready_max_days	30	Потолок готовности, суток	Каждые сутки простоя после сдачи прибавляют к очереди единицу, но не больше этого числа. Без потолка вернувшийся из отпуска месяцами вытеснял бы остальных. Ни разу не заступавший получает потолок сразу.	\N	2026-09-19 14:40:58.204035+07
queue.unassigned_bonus	0	Надбавка ни разу не заступавшим	Прибавляется к потолку готовности тому, у кого нет ни одного наряда за все время учета (новичок, только что принятый). 0 — новичок наравне с давно не ходившим; больше 0 — идет первым.	\N	2026-09-19 14:40:58.204035+07
queue.workload_factor	0.3	Вес накопленной нагрузки	Нагрузка — сумма весов нарядов за 30 суток до заступления: наряд в рабочий день — вес его вида, в выходной или праздник — ×1,5, плюс 0,5 за каждые сутки отсыпного. Очередь понижается на нагрузку × это число. 0 — частота не учитывается; 1 — нагрузка весит как готовность.	\N	2026-09-19 14:48:35.540244+07
\.


--
-- Data for Name: units; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.units (id, name, short_name, parent_id, sort_order, is_active, created_at, updated_at, commander_employee_id, staff_count, is_headquarters) FROM stdin;
12	1 отделение	1 отделение	6	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	90	5	f
2	Вторая рота	2 рота	1	20	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	9	39	f
3	Первая рота	1 рота	1	10	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	8	37	f
4	Узел связи	УС	1	30	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	146	39	f
5	Техническая служба	ТС	1	40	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	11	40	f
6	1 взвод роты	1 взвод	2	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	33	14	f
7	2 взвод роты	2 взвод	2	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	86	13	f
8	3 взвод роты	3 взвод	2	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	88	13	f
9	1 взвод роты	1 взвод	3	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	32	14	f
10	2 взвод роты	2 взвод	3	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	87	13	f
11	3 взвод роты	3 взвод	3	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	89	13	f
49	Псих служба	ПС	1	50	t	2026-09-27 14:33:34.570787+07	2026-09-27 14:33:34.570787+07	\N	\N	f
20	3 отделение	3 отделение	8	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	72	6	f
25	2 отделение	2 отделение	10	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	85	5	f
26	3 отделение	3 отделение	10	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	73	6	f
27	1 отделение	1 отделение	11	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	75	4	f
17	3 отделение	3 отделение	7	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	5	6	f
18	1 отделение	1 отделение	8	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	17	4	f
15	1 отделение	1 отделение	7	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	82	5	f
13	2 отделение	2 отделение	6	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	92	6	f
21	1 отделение	1 отделение	9	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	91	5	f
19	2 отделение	2 отделение	8	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	29	5	f
24	1 отделение	1 отделение	10	10	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	83	5	f
28	2 отделение	2 отделение	11	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	77	5	f
29	3 отделение	3 отделение	11	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	4	6	f
16	2 отделение	2 отделение	7	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	84	5	f
23	3 отделение	3 отделение	9	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	81	7	f
22	2 отделение	2 отделение	9	20	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	79	6	f
14	3 отделение	3 отделение	6	30	t	2026-09-13 12:58:06.823516+07	2026-09-27 13:59:22.24411+07	80	7	f
1	В/Ч 00011	в/ч 00011	\N	0	t	2026-08-24 14:54:07.128601+07	2026-09-27 14:36:10.921284+07	165	172	f
50	Штаб	Штаб	1	5	t	2026-09-27 14:49:18.755948+07	2026-09-27 14:49:18.755948+07	171	\N	t
33	Управление	Управление	1	0	t	2026-09-19 14:03:46.148105+07	2026-09-27 14:54:46.931661+07	170	25	f
\.


--
-- Data for Name: user_permissions; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.user_permissions (user_id, permission_code, granted, note, granted_by, granted_at) FROM stdin;
2	calendar.manage	f	\N	1	2026-09-13 12:27:34.713171+07
19	duty.approve	t	\N	1	2026-09-13 12:41:39.85055+07
19	duty.withdraw	t	\N	1	2026-09-13 12:41:39.85055+07
19	duty.override	t	\N	1	2026-09-13 12:41:39.85055+07
19	post.manage	t	\N	1	2026-09-13 12:41:39.85055+07
19	calendar.manage	t	\N	1	2026-09-13 12:41:39.85055+07
19	personnel.view	t	\N	1	2026-09-13 12:41:39.85055+07
19	weapon.transfer	t	\N	1	2026-09-13 12:41:39.85055+07
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: core; Owner: -
--

COPY core.users (id, employee_id, login, password_hash, role_code, failed_attempts, locked_until, is_active, created_at, updated_at, must_change_password, password_changed_at, last_login_at, created_by, scope_unit_id) FROM stdin;
19	137	bvs	scrypt$131072$8$1$CT4FkwORkXYnGpGwxnXZwg==$0X4mMujhAHldpFwnQrQrxhX2KMYMSEAyMXUGxQWF3fM=	chief	0	\N	t	2026-09-13 12:41:39.842778+07	2026-09-28 15:39:42.072081+07	f	2026-09-13 12:42:15.501234+07	\N	1	\N
20	\N	rota1	scrypt$131072$8$1$CT4FkwORkXYnGpGwxnXZwg==$0X4mMujhAHldpFwnQrQrxhX2KMYMSEAyMXUGxQWF3fM=	commander	0	\N	t	2026-09-19 13:57:44.811891+07	2026-09-28 15:39:42.072081+07	f	2026-09-19 13:57:45.737893+07	\N	1	3
1	1	admin	scrypt$131072$8$1$CT4FkwORkXYnGpGwxnXZwg==$0X4mMujhAHldpFwnQrQrxhX2KMYMSEAyMXUGxQWF3fM=	admin	0	\N	t	2026-08-24 14:54:07.128601+07	2026-09-28 15:39:42.072081+07	f	2026-09-13 12:23:27.845372+07	\N	\N	\N
195	\N	check.runner	scrypt$131072$8$1$CT4FkwORkXYnGpGwxnXZwg==$0X4mMujhAHldpFwnQrQrxhX2KMYMSEAyMXUGxQWF3fM=	admin	0	\N	t	2026-09-27 19:27:25.127631+07	2026-09-28 15:39:42.072081+07	f	2026-09-27 19:27:25.127631+07	\N	\N	\N
2	\N	komandir1	scrypt$131072$8$1$CT4FkwORkXYnGpGwxnXZwg==$0X4mMujhAHldpFwnQrQrxhX2KMYMSEAyMXUGxQWF3fM=	user	0	\N	t	2026-09-13 12:13:06.659873+07	2026-09-28 15:39:42.072081+07	f	2026-09-13 12:13:17.576989+07	\N	1	\N
\.


--
-- Data for Name: duties; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.duties (id, duty_type_id, unit_id, starts_at, ends_at, status, created_by, approved_by, approved_at, note, created_at, updated_at, unapproved_by, unapproved_at, approved_snapshot, order_snapshot, order_deadline, start_date) FROM stdin;
1510	5	1	2026-09-21 10:00:00+07	2026-09-22 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.181814+07	2026-09-20 19:05:20.181814+07	\N	\N	\N	\N	\N	2026-09-21
2	2	1	2026-08-25 10:30:00+07	2026-08-26 10:30:00+07	draft	\N	\N	\N	Проверка постов, данные синтетические	2026-08-24 15:38:50.300274+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 2, "note": "Проверка постов, данные синтетические", "status": "draft", "ends_at": "2026-08-26T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-08-25T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 7, "full_name": "Жданов Кирилл Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 34, "full_name": "Жуков Виктор Николаевич", "rank_name": "капитан", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 9, "full_name": "Ильин Михаил Михайлович", "rank_name": "лейтенант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 4, "full_name": "Гусев Дмитрий Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 5, "full_name": "Данилов Евгений Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 6, "full_name": "Ершов Иван Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 35, "full_name": "Зимин Григорий Олегович", "rank_name": "майор", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 17, "full_name": "Сафонов Борис Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	\N	2026-08-24	2026-08-25
1511	5	1	2026-09-22 10:00:00+07	2026-09-23 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.299447+07	2026-09-20 19:05:20.299447+07	\N	\N	\N	\N	\N	2026-09-22
1512	5	1	2026-09-23 10:00:00+07	2026-09-24 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.380605+07	2026-09-20 19:05:20.380605+07	\N	\N	\N	\N	\N	2026-09-23
1513	5	1	2026-09-24 10:00:00+07	2026-09-25 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.459356+07	2026-09-20 19:05:20.459356+07	\N	\N	\N	\N	\N	2026-09-24
1514	5	1	2026-09-25 10:00:00+07	2026-09-26 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.537317+07	2026-09-20 19:05:20.537317+07	\N	\N	\N	\N	\N	2026-09-25
1515	5	1	2026-09-26 10:00:00+07	2026-09-27 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.622891+07	2026-09-20 19:05:20.622891+07	\N	\N	\N	\N	\N	2026-09-26
1516	5	1	2026-09-27 10:00:00+07	2026-09-28 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.622891+07	2026-09-20 19:05:20.622891+07	\N	\N	\N	\N	\N	2026-09-27
450	2	1	2026-10-31 10:30:00+07	2026-11-01 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 14:44:26.888607+07	2026-09-19 14:44:26.888607+07	\N	\N	\N	\N	\N	2026-10-31
600	2	1	2026-12-30 10:30:00+07	2026-12-31 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:50:53.756938+07	2026-09-19 14:50:53.756938+07	\N	\N	\N	\N	\N	2026-12-30
1021	2	1	2027-01-16 10:30:00+07	2027-01-17 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.355197+07	2026-09-19 14:57:04.355197+07	\N	\N	\N	\N	\N	2027-01-16
1022	2	1	2027-01-17 10:30:00+07	2027-01-18 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.359803+07	2026-09-19 14:57:04.359803+07	\N	\N	\N	\N	\N	2027-01-17
1023	2	1	2027-01-18 10:30:00+07	2027-01-19 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.361401+07	2026-09-19 14:57:04.361401+07	\N	\N	\N	\N	\N	2027-01-18
1033	2	1	2027-01-28 10:30:00+07	2027-01-29 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:06.198679+07	2026-09-19 14:57:06.198679+07	\N	\N	\N	\N	\N	2027-01-28
1035	2	1	2027-01-30 10:30:00+07	2027-01-31 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:06.56379+07	2026-09-19 14:57:06.56379+07	\N	\N	\N	\N	\N	2027-01-30
1036	2	1	2027-01-31 10:30:00+07	2027-02-01 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:06.565822+07	2026-09-19 14:57:06.565822+07	\N	\N	\N	\N	\N	2027-01-31
1059	3	1	2027-01-22 10:00:00+07	2027-01-23 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.658697+07	2026-09-19 14:57:09.658697+07	\N	\N	\N	\N	\N	2027-01-22
1063	3	1	2027-01-26 10:00:00+07	2027-01-27 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.017623+07	2026-09-19 14:57:10.017623+07	\N	\N	\N	\N	\N	2027-01-26
1176	2	1	2027-02-19 10:30:00+07	2027-02-20 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:51.277248+07	2026-09-19 15:01:51.277248+07	\N	\N	\N	\N	\N	2027-02-19
1128	2	1	2026-11-01 10:30:00+07	2026-11-02 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:44.195095+07	2026-09-19 15:01:44.195095+07	\N	\N	\N	\N	\N	2026-11-01
1129	2	1	2026-11-02 10:30:00+07	2026-11-03 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:44.198682+07	2026-09-19 15:01:44.198682+07	\N	\N	\N	\N	\N	2026-11-02
1137	2	1	2026-11-10 10:30:00+07	2026-11-11 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.454836+07	2026-09-19 15:01:45.454836+07	\N	\N	\N	\N	\N	2026-11-10
1139	2	1	2026-11-12 10:30:00+07	2026-11-13 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.66162+07	2026-09-19 15:01:45.66162+07	\N	\N	\N	\N	\N	2026-11-12
1144	2	1	2026-11-17 10:30:00+07	2026-11-18 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.351324+07	2026-09-19 15:01:46.351324+07	\N	\N	\N	\N	\N	2026-11-17
1146	2	1	2026-11-19 10:30:00+07	2026-11-20 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.558406+07	2026-09-19 15:01:46.558406+07	\N	\N	\N	\N	\N	2026-11-19
1152	2	1	2026-11-25 10:30:00+07	2026-11-26 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.335703+07	2026-09-19 15:01:47.335703+07	\N	\N	\N	\N	\N	2026-11-25
1154	2	1	2026-11-27 10:30:00+07	2026-11-28 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.554991+07	2026-09-19 15:01:47.554991+07	\N	\N	\N	\N	\N	2026-11-27
1158	2	1	2027-02-01 10:30:00+07	2027-02-02 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:48.318036+07	2026-09-19 15:01:48.318036+07	\N	\N	\N	\N	\N	2027-02-01
1163	2	1	2027-02-06 10:30:00+07	2027-02-07 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:49.135971+07	2026-09-19 15:01:49.135971+07	\N	\N	\N	\N	\N	2027-02-06
1164	2	1	2027-02-07 10:30:00+07	2027-02-08 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:49.144097+07	2026-09-19 15:01:49.144097+07	\N	\N	\N	\N	\N	2027-02-07
1165	2	1	2027-02-08 10:30:00+07	2027-02-09 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:49.145462+07	2026-09-19 15:01:49.145462+07	\N	\N	\N	\N	\N	2027-02-08
1167	2	1	2027-02-10 10:30:00+07	2027-02-11 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:49.784885+07	2026-09-19 15:01:49.784885+07	\N	\N	\N	\N	\N	2027-02-10
1175	2	1	2027-02-18 10:30:00+07	2027-02-19 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:51.12694+07	2026-09-19 15:01:51.12694+07	\N	\N	\N	\N	\N	2027-02-18
1463	2	1	2026-12-15 10:30:00+07	2026-12-16 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.453698+07	2026-09-19 15:20:09.453698+07	\N	\N	\N	\N	\N	2026-12-15
1456	2	1	2026-12-08 10:30:00+07	2026-12-09 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:08.505331+07	2026-09-19 15:20:08.505331+07	\N	\N	\N	\N	\N	2026-12-08
1466	2	1	2026-12-18 10:30:00+07	2026-12-19 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.826397+07	2026-09-19 15:20:09.826397+07	\N	\N	\N	\N	\N	2026-12-18
1467	2	1	2026-12-19 10:30:00+07	2026-12-20 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.041988+07	2026-09-19 15:20:10.041988+07	\N	\N	\N	\N	\N	2026-12-19
1468	2	1	2026-12-20 10:30:00+07	2026-12-21 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.050001+07	2026-09-19 15:20:10.050001+07	\N	\N	\N	\N	\N	2026-12-20
1469	2	1	2026-12-21 10:30:00+07	2026-12-22 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.051048+07	2026-09-19 15:20:10.051048+07	\N	\N	\N	\N	\N	2026-12-21
1473	2	1	2026-12-25 10:30:00+07	2026-12-26 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.891229+07	2026-09-19 15:20:10.891229+07	\N	\N	\N	\N	\N	2026-12-25
1478	3	1	2026-10-02 10:00:00+07	2026-10-03 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:50.706035+07	2026-09-19 16:45:50.706035+07	\N	\N	\N	\N	\N	2026-10-02
1483	3	1	2026-10-07 10:00:00+07	2026-10-08 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.126275+07	2026-09-19 16:45:51.126275+07	\N	\N	\N	\N	\N	2026-10-07
1486	3	1	2026-10-10 10:00:00+07	2026-10-11 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.376423+07	2026-09-19 16:45:51.376423+07	\N	\N	\N	\N	\N	2026-10-10
1487	3	1	2026-10-11 10:00:00+07	2026-10-12 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.384324+07	2026-09-19 16:45:51.384324+07	\N	\N	\N	\N	\N	2026-10-11
1488	3	1	2026-10-12 10:00:00+07	2026-10-13 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.385335+07	2026-09-19 16:45:51.385335+07	\N	\N	\N	\N	\N	2026-10-12
1491	3	1	2026-10-15 10:00:00+07	2026-10-16 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.725022+07	2026-09-19 16:45:51.725022+07	\N	\N	\N	\N	\N	2026-10-15
1493	3	1	2026-10-17 10:00:00+07	2026-10-18 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.902528+07	2026-09-19 16:45:51.902528+07	\N	\N	\N	\N	\N	2026-10-17
1494	3	1	2026-10-18 10:00:00+07	2026-10-19 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.903765+07	2026-09-19 16:45:51.903765+07	\N	\N	\N	\N	\N	2026-10-18
1495	3	1	2026-10-19 10:00:00+07	2026-10-20 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.904715+07	2026-09-19 16:45:51.904715+07	\N	\N	\N	\N	\N	2026-10-19
1496	3	1	2026-10-20 10:00:00+07	2026-10-21 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.109082+07	2026-09-19 16:45:52.109082+07	\N	\N	\N	\N	\N	2026-10-20
1498	3	1	2026-10-22 10:00:00+07	2026-10-23 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.262735+07	2026-09-19 16:45:52.262735+07	\N	\N	\N	\N	\N	2026-10-22
1500	3	1	2026-10-24 10:00:00+07	2026-10-25 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.442633+07	2026-09-19 16:45:52.442633+07	\N	\N	\N	\N	\N	2026-10-24
1501	3	1	2026-10-25 10:00:00+07	2026-10-26 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.450371+07	2026-09-19 16:45:52.450371+07	\N	\N	\N	\N	\N	2026-10-25
1502	3	1	2026-10-26 10:00:00+07	2026-10-27 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.45138+07	2026-09-19 16:45:52.45138+07	\N	\N	\N	\N	\N	2026-10-26
1506	3	1	2026-10-30 10:00:00+07	2026-10-31 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.870416+07	2026-09-19 16:45:52.870416+07	\N	\N	\N	\N	\N	2026-10-30
1507	3	1	2026-10-31 10:00:00+07	2026-11-01 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.977968+07	2026-09-19 16:45:52.977968+07	\N	\N	\N	\N	\N	2026-10-31
1508	3	1	2026-11-01 10:00:00+07	2026-11-02 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.985833+07	2026-09-19 16:45:52.985833+07	\N	\N	\N	\N	\N	2026-11-01
1509	3	1	2026-11-02 10:00:00+07	2026-11-03 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.986797+07	2026-09-19 16:45:52.986797+07	\N	\N	\N	\N	\N	2026-11-02
1517	5	1	2026-09-28 10:00:00+07	2026-09-29 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.622891+07	2026-09-20 19:05:20.622891+07	\N	\N	\N	\N	\N	2026-09-28
1518	5	1	2026-09-29 10:00:00+07	2026-09-30 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.749817+07	2026-09-20 19:05:20.749817+07	\N	\N	\N	\N	\N	2026-09-29
346	1	1	2026-09-15 17:30:00+07	2026-09-18 17:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.779781+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-15
1519	5	1	2026-09-30 10:00:00+07	2026-10-01 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:20.825698+07	2026-09-20 19:05:20.825698+07	\N	\N	\N	\N	\N	2026-09-30
349	1	1	2026-09-25 17:30:00+07	2026-09-29 17:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.798386+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-25
350	1	1	2026-09-29 17:30:00+07	2026-10-02 17:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.804359+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-29
367	2	1	2026-09-17 10:30:00+07	2026-09-18 10:30:00+07	approved	\N	1	2026-09-12 00:21:45.73093+07	\N	2026-09-07 14:47:53.975058+07	2026-09-12 00:21:45.73093+07	\N	\N	{"duty": {"id": 367, "note": null, "status": "approved", "ends_at": "2026-09-18T03:30:00.000Z", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-17T03:30:00.000Z", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [{"id": 135, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 137, "is_active": true, "serial_number": "TEST-137", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 137, "position": "начальник службы", "full_name": "Панкратов Юрий Евгеньевич", "last_name": "Панкратов", "rank_name": "капитан", "seniority": 120, "first_name": "Юрий", "rank_short": "к-н", "short_name": "к-н Панкратов Ю.Е.", "unit_short": "УС", "middle_name": "Евгеньевич", "personnel_number": "С-01097"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [{"id": 95, "kind": "rifle", "name": "Учебный автомат", "owner_id": 97, "is_active": true, "serial_number": "TEST-97", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 97, "position": "техник", "full_name": "Панкратов Тимур Тимурович", "last_name": "Панкратов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Тимур", "rank_short": "пр-к", "short_name": "пр-к Панкратов Т.Т.", "unit_short": "ТС", "middle_name": "Тимурович", "personnel_number": "С-01057"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 89, "kind": "rifle", "name": "Учебный автомат", "owner_id": 91, "is_active": true, "serial_number": "TEST-91", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 91, "position": "командир отделения", "full_name": "Зотов Геннадий Геннадьевич", "last_name": "Зотов", "rank_name": "старшина", "seniority": 60, "first_name": "Геннадий", "rank_short": "ст-на", "short_name": "ст-на Зотов Г.Г.", "unit_short": "1 рота", "middle_name": "Геннадьевич", "personnel_number": "С-01051"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 68, "kind": "rifle", "name": "Учебный автомат", "owner_id": 70, "is_active": true, "serial_number": "TEST-70", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 70, "position": "командир отделения", "full_name": "Абрамов Игорь Игоревич", "last_name": "Абрамов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Игорь", "rank_short": "мл. с-т", "short_name": "мл. с-т Абрамов И.И.", "unit_short": "2 рота", "middle_name": "Игоревич", "personnel_number": "С-01030"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 65, "kind": "rifle", "name": "Учебный автомат", "owner_id": 67, "is_active": true, "serial_number": "TEST-67", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 67, "position": "стрелок", "full_name": "Панкратов Максим Максимович", "last_name": "Панкратов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Максим", "rank_short": "ефр.", "short_name": "ефр. Панкратов М.М.", "unit_short": "1 рота", "middle_name": "Максимович", "personnel_number": "С-01027"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 67, "kind": "rifle", "name": "Учебный автомат", "owner_id": 69, "is_active": true, "serial_number": "TEST-69", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 69, "position": "стрелок", "full_name": "Бобров Борис Романович", "last_name": "Бобров", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Борис", "rank_short": "ефр.", "short_name": "ефр. Бобров Б.Р.", "unit_short": "1 рота", "middle_name": "Романович", "personnel_number": "С-01029"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 46, "kind": "rifle", "name": "Учебный автомат", "owner_id": 48, "is_active": true, "serial_number": "TEST-48", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 48, "position": "стрелок", "full_name": "Цветков Дмитрий Фёдорович", "last_name": "Цветков", "rank_name": "рядовой", "seniority": 10, "first_name": "Дмитрий", "rank_short": "р-й", "short_name": "р-й Цветков Д.Ф.", "unit_short": "2 рота", "middle_name": "Фёдорович", "personnel_number": "С-01008"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 50, "kind": "rifle", "name": "Учебный автомат", "owner_id": 52, "is_active": true, "serial_number": "TEST-52", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 52, "position": "стрелок", "full_name": "Панкратов Игорь Игоревич", "last_name": "Панкратов", "rank_name": "рядовой", "seniority": 10, "first_name": "Игорь", "rank_short": "р-й", "short_name": "р-й Панкратов И.И.", "unit_short": "2 рота", "middle_name": "Игоревич", "personnel_number": "С-01012"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [{"id": 4, "kind": "rifle", "name": "Учебный автомат", "owner_id": 5, "is_active": true, "serial_number": "TEST-5", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 5, "position": "старший техник", "full_name": "Данилов Евгений Евгеньевич", "last_name": "Данилов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Данилов Е.Е.", "unit_short": "2 рота", "middle_name": "Евгеньевич", "personnel_number": "Т-0005"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [{"id": 26, "kind": "rifle", "name": "Учебный автомат", "owner_id": 28, "is_active": true, "serial_number": "TEST-28", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 28, "position": "оператор", "full_name": "Антонов Павел Дмитриевич", "last_name": "Антонов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Павел", "rank_short": "мл. с-т", "short_name": "мл. с-т Антонов П.Д.", "unit_short": "1 рота", "middle_name": "Дмитриевич", "personnel_number": "Т-0028"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [{"id": 5, "kind": "rifle", "name": "Учебный автомат", "owner_id": 6, "is_active": true, "serial_number": "TEST-6", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 6, "position": "командир отделения", "full_name": "Ершов Иван Иванович", "last_name": "Ершов", "rank_name": "старший сержант", "seniority": 50, "first_name": "Иван", "rank_short": "ст. с-т", "short_name": "ст. с-т Ершов И.И.", "unit_short": "УС", "middle_name": "Иванович", "personnel_number": "Т-0006"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [{"id": 34, "kind": "rifle", "name": "Учебный автомат", "owner_id": 36, "is_active": true, "serial_number": "TEST-36", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 36, "position": "оператор", "full_name": "Исаев Дмитрий Александрович", "last_name": "Исаев", "rank_name": "рядовой", "seniority": 10, "first_name": "Дмитрий", "rank_short": "р-й", "short_name": "р-й Исаев Д.А.", "unit_short": "1 рота", "middle_name": "Александрович", "personnel_number": "Т-0036"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 367, "note": null, "status": "approved", "ends_at": "2026-09-18T03:30:00.000Z", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-17T03:30:00.000Z", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [{"id": 135, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 137, "is_active": true, "serial_number": "TEST-137", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 137, "position": "начальник службы", "full_name": "Панкратов Юрий Евгеньевич", "last_name": "Панкратов", "rank_name": "капитан", "seniority": 120, "first_name": "Юрий", "rank_short": "к-н", "short_name": "к-н Панкратов Ю.Е.", "unit_short": "УС", "middle_name": "Евгеньевич", "personnel_number": "С-01097"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [{"id": 95, "kind": "rifle", "name": "Учебный автомат", "owner_id": 97, "is_active": true, "serial_number": "TEST-97", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 97, "position": "техник", "full_name": "Панкратов Тимур Тимурович", "last_name": "Панкратов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Тимур", "rank_short": "пр-к", "short_name": "пр-к Панкратов Т.Т.", "unit_short": "ТС", "middle_name": "Тимурович", "personnel_number": "С-01057"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 89, "kind": "rifle", "name": "Учебный автомат", "owner_id": 91, "is_active": true, "serial_number": "TEST-91", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 91, "position": "командир отделения", "full_name": "Зотов Геннадий Геннадьевич", "last_name": "Зотов", "rank_name": "старшина", "seniority": 60, "first_name": "Геннадий", "rank_short": "ст-на", "short_name": "ст-на Зотов Г.Г.", "unit_short": "1 рота", "middle_name": "Геннадьевич", "personnel_number": "С-01051"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 68, "kind": "rifle", "name": "Учебный автомат", "owner_id": 70, "is_active": true, "serial_number": "TEST-70", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 70, "position": "командир отделения", "full_name": "Абрамов Игорь Игоревич", "last_name": "Абрамов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Игорь", "rank_short": "мл. с-т", "short_name": "мл. с-т Абрамов И.И.", "unit_short": "2 рота", "middle_name": "Игоревич", "personnel_number": "С-01030"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 65, "kind": "rifle", "name": "Учебный автомат", "owner_id": 67, "is_active": true, "serial_number": "TEST-67", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 67, "position": "стрелок", "full_name": "Панкратов Максим Максимович", "last_name": "Панкратов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Максим", "rank_short": "ефр.", "short_name": "ефр. Панкратов М.М.", "unit_short": "1 рота", "middle_name": "Максимович", "personnel_number": "С-01027"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 67, "kind": "rifle", "name": "Учебный автомат", "owner_id": 69, "is_active": true, "serial_number": "TEST-69", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 69, "position": "стрелок", "full_name": "Бобров Борис Романович", "last_name": "Бобров", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Борис", "rank_short": "ефр.", "short_name": "ефр. Бобров Б.Р.", "unit_short": "1 рота", "middle_name": "Романович", "personnel_number": "С-01029"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 46, "kind": "rifle", "name": "Учебный автомат", "owner_id": 48, "is_active": true, "serial_number": "TEST-48", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 48, "position": "стрелок", "full_name": "Цветков Дмитрий Фёдорович", "last_name": "Цветков", "rank_name": "рядовой", "seniority": 10, "first_name": "Дмитрий", "rank_short": "р-й", "short_name": "р-й Цветков Д.Ф.", "unit_short": "2 рота", "middle_name": "Фёдорович", "personnel_number": "С-01008"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 50, "kind": "rifle", "name": "Учебный автомат", "owner_id": 52, "is_active": true, "serial_number": "TEST-52", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 52, "position": "стрелок", "full_name": "Панкратов Игорь Игоревич", "last_name": "Панкратов", "rank_name": "рядовой", "seniority": 10, "first_name": "Игорь", "rank_short": "р-й", "short_name": "р-й Панкратов И.И.", "unit_short": "2 рота", "middle_name": "Игоревич", "personnel_number": "С-01012"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [{"id": 4, "kind": "rifle", "name": "Учебный автомат", "owner_id": 5, "is_active": true, "serial_number": "TEST-5", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 5, "position": "старший техник", "full_name": "Данилов Евгений Евгеньевич", "last_name": "Данилов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Данилов Е.Е.", "unit_short": "2 рота", "middle_name": "Евгеньевич", "personnel_number": "Т-0005"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [{"id": 26, "kind": "rifle", "name": "Учебный автомат", "owner_id": 28, "is_active": true, "serial_number": "TEST-28", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 28, "position": "оператор", "full_name": "Антонов Павел Дмитриевич", "last_name": "Антонов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Павел", "rank_short": "мл. с-т", "short_name": "мл. с-т Антонов П.Д.", "unit_short": "1 рота", "middle_name": "Дмитриевич", "personnel_number": "Т-0028"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [{"id": 5, "kind": "rifle", "name": "Учебный автомат", "owner_id": 6, "is_active": true, "serial_number": "TEST-6", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 6, "position": "командир отделения", "full_name": "Ершов Иван Иванович", "last_name": "Ершов", "rank_name": "старший сержант", "seniority": 50, "first_name": "Иван", "rank_short": "ст. с-т", "short_name": "ст. с-т Ершов И.И.", "unit_short": "УС", "middle_name": "Иванович", "personnel_number": "Т-0006"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [{"id": 34, "kind": "rifle", "name": "Учебный автомат", "owner_id": 36, "is_active": true, "serial_number": "TEST-36", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 36, "position": "оператор", "full_name": "Исаев Дмитрий Александрович", "last_name": "Исаев", "rank_name": "рядовой", "seniority": 10, "first_name": "Дмитрий", "rank_short": "р-й", "short_name": "р-й Исаев Д.А.", "unit_short": "1 рота", "middle_name": "Александрович", "personnel_number": "Т-0036"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-16", "totalAssigned": 12}	2026-09-16	2026-09-17
368	2	1	2026-09-18 10:30:00+07	2026-09-19 10:30:00+07	approved	\N	1	2026-09-12 00:29:38.045339+07	\N	2026-09-07 14:47:53.980923+07	2026-09-12 00:29:38.045339+07	\N	\N	{"duty": {"id": 368, "note": null, "status": "approved", "ends_at": "2026-09-19T03:30:00.000Z", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-18T03:30:00.000Z", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [{"id": 136, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 138, "is_active": true, "serial_number": "TEST-138", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 138, "position": "начальник службы", "full_name": "Цветков Дмитрий Фёдорович", "last_name": "Цветков", "rank_name": "капитан", "seniority": 120, "first_name": "Дмитрий", "rank_short": "к-н", "short_name": "к-н Цветков Д.Ф.", "unit_short": "ТС", "middle_name": "Фёдорович", "personnel_number": "С-01098"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [{"id": 97, "kind": "rifle", "name": "Учебный автомат", "owner_id": 99, "is_active": true, "serial_number": "TEST-99", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 99, "position": "техник", "full_name": "Бобров Кирилл Борисович", "last_name": "Бобров", "rank_name": "прапорщик", "seniority": 70, "first_name": "Кирилл", "rank_short": "пр-к", "short_name": "пр-к Бобров К.Б.", "unit_short": "ТС", "middle_name": "Борисович", "personnel_number": "С-01059"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 75, "kind": "rifle", "name": "Учебный автомат", "owner_id": 77, "is_active": true, "serial_number": "TEST-77", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 77, "position": "командир отделения", "full_name": "Панкратов Евгений Олегович", "last_name": "Панкратов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Панкратов Е.О.", "unit_short": "1 рота", "middle_name": "Олегович", "personnel_number": "С-01037"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 70, "kind": "rifle", "name": "Учебный автомат", "owner_id": 72, "is_active": true, "serial_number": "TEST-72", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 72, "position": "командир отделения", "full_name": "Панкратов Фёдор Николаевич", "last_name": "Панкратов", "rank_name": "сержант", "seniority": 40, "first_name": "Фёдор", "rank_short": "с-т", "short_name": "с-т Панкратов Ф.Н.", "unit_short": "2 рота", "middle_name": "Николаевич", "personnel_number": "С-01032"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 41, "kind": "rifle", "name": "Учебный автомат", "owner_id": 43, "is_active": true, "serial_number": "TEST-43", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 43, "position": "стрелок", "full_name": "Цветков Тимур Тимурович", "last_name": "Цветков", "rank_name": "рядовой", "seniority": 10, "first_name": "Тимур", "rank_short": "р-й", "short_name": "р-й Цветков Т.Т.", "unit_short": "1 рота", "middle_name": "Тимурович", "personnel_number": "С-01003"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 43, "kind": "rifle", "name": "Учебный автомат", "owner_id": 45, "is_active": true, "serial_number": "TEST-45", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 45, "position": "стрелок", "full_name": "Абрамов Кирилл Борисович", "last_name": "Абрамов", "rank_name": "рядовой", "seniority": 10, "first_name": "Кирилл", "rank_short": "р-й", "short_name": "р-й Абрамов К.Б.", "unit_short": "1 рота", "middle_name": "Борисович", "personnel_number": "С-01005"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 56, "kind": "rifle", "name": "Учебный автомат", "owner_id": 58, "is_active": true, "serial_number": "TEST-58", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 58, "position": "стрелок", "full_name": "Цветков Александр Александрович", "last_name": "Цветков", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Александр", "rank_short": "ефр.", "short_name": "ефр. Цветков А.А.", "unit_short": "2 рота", "middle_name": "Александрович", "personnel_number": "С-01018"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 58, "kind": "rifle", "name": "Учебный автомат", "owner_id": 60, "is_active": true, "serial_number": "TEST-60", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 60, "position": "стрелок", "full_name": "Абрамов Николай Дмитриевич", "last_name": "Абрамов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Николай", "rank_short": "ефр.", "short_name": "ефр. Абрамов Н.Д.", "unit_short": "2 рота", "middle_name": "Дмитриевич", "personnel_number": "С-01020"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [{"id": 6, "kind": "rifle", "name": "Учебный автомат", "owner_id": 7, "is_active": true, "serial_number": "TEST-7", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 7, "position": "заместитель командира взвода", "full_name": "Жданов Кирилл Кириллович", "last_name": "Жданов", "rank_name": "старшина", "seniority": 60, "first_name": "Кирилл", "rank_short": "ст-на", "short_name": "ст-на Жданов К.К.", "unit_short": "ТС", "middle_name": "Кириллович", "personnel_number": "Т-0007"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [{"id": 36, "kind": "rifle", "name": "Учебный автомат", "owner_id": 38, "is_active": true, "serial_number": "TEST-38", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 38, "position": "командир отделения", "full_name": "Лукин Иван Викторович", "last_name": "Лукин", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Иван", "rank_short": "ефр.", "short_name": "ефр. Лукин И.В.", "unit_short": "УС", "middle_name": "Викторович", "personnel_number": "Т-0038"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [{"id": 52, "kind": "rifle", "name": "Учебный автомат", "owner_id": 54, "is_active": true, "serial_number": "TEST-54", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 54, "position": "стрелок", "full_name": "Бобров Фёдор Николаевич", "last_name": "Бобров", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Фёдор", "rank_short": "ефр.", "short_name": "ефр. Бобров Ф.Н.", "unit_short": "2 рота", "middle_name": "Николаевич", "personnel_number": "С-01014"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [{"id": 39, "kind": "rifle", "name": "Учебный автомат", "owner_id": 41, "is_active": true, "serial_number": "TEST-41", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 41, "position": "стрелок", "full_name": "Зотов Евгений Олегович", "last_name": "Зотов", "rank_name": "рядовой", "seniority": 10, "first_name": "Евгений", "rank_short": "р-й", "short_name": "р-й Зотов Е.О.", "unit_short": "1 рота", "middle_name": "Олегович", "personnel_number": "С-01001"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 368, "note": null, "status": "approved", "ends_at": "2026-09-19T03:30:00.000Z", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-18T03:30:00.000Z", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [{"id": 136, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 138, "is_active": true, "serial_number": "TEST-138", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 138, "position": "начальник службы", "full_name": "Цветков Дмитрий Фёдорович", "last_name": "Цветков", "rank_name": "капитан", "seniority": 120, "first_name": "Дмитрий", "rank_short": "к-н", "short_name": "к-н Цветков Д.Ф.", "unit_short": "ТС", "middle_name": "Фёдорович", "personnel_number": "С-01098"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [{"id": 97, "kind": "rifle", "name": "Учебный автомат", "owner_id": 99, "is_active": true, "serial_number": "TEST-99", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 99, "position": "техник", "full_name": "Бобров Кирилл Борисович", "last_name": "Бобров", "rank_name": "прапорщик", "seniority": 70, "first_name": "Кирилл", "rank_short": "пр-к", "short_name": "пр-к Бобров К.Б.", "unit_short": "ТС", "middle_name": "Борисович", "personnel_number": "С-01059"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 75, "kind": "rifle", "name": "Учебный автомат", "owner_id": 77, "is_active": true, "serial_number": "TEST-77", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 77, "position": "командир отделения", "full_name": "Панкратов Евгений Олегович", "last_name": "Панкратов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Панкратов Е.О.", "unit_short": "1 рота", "middle_name": "Олегович", "personnel_number": "С-01037"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [{"id": 70, "kind": "rifle", "name": "Учебный автомат", "owner_id": 72, "is_active": true, "serial_number": "TEST-72", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 72, "position": "командир отделения", "full_name": "Панкратов Фёдор Николаевич", "last_name": "Панкратов", "rank_name": "сержант", "seniority": 40, "first_name": "Фёдор", "rank_short": "с-т", "short_name": "с-т Панкратов Ф.Н.", "unit_short": "2 рота", "middle_name": "Николаевич", "personnel_number": "С-01032"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 41, "kind": "rifle", "name": "Учебный автомат", "owner_id": 43, "is_active": true, "serial_number": "TEST-43", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 43, "position": "стрелок", "full_name": "Цветков Тимур Тимурович", "last_name": "Цветков", "rank_name": "рядовой", "seniority": 10, "first_name": "Тимур", "rank_short": "р-й", "short_name": "р-й Цветков Т.Т.", "unit_short": "1 рота", "middle_name": "Тимурович", "personnel_number": "С-01003"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 43, "kind": "rifle", "name": "Учебный автомат", "owner_id": 45, "is_active": true, "serial_number": "TEST-45", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 45, "position": "стрелок", "full_name": "Абрамов Кирилл Борисович", "last_name": "Абрамов", "rank_name": "рядовой", "seniority": 10, "first_name": "Кирилл", "rank_short": "р-й", "short_name": "р-й Абрамов К.Б.", "unit_short": "1 рота", "middle_name": "Борисович", "personnel_number": "С-01005"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [{"id": 56, "kind": "rifle", "name": "Учебный автомат", "owner_id": 58, "is_active": true, "serial_number": "TEST-58", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 58, "position": "стрелок", "full_name": "Цветков Александр Александрович", "last_name": "Цветков", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Александр", "rank_short": "ефр.", "short_name": "ефр. Цветков А.А.", "unit_short": "2 рота", "middle_name": "Александрович", "personnel_number": "С-01018"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [{"id": 58, "kind": "rifle", "name": "Учебный автомат", "owner_id": 60, "is_active": true, "serial_number": "TEST-60", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 60, "position": "стрелок", "full_name": "Абрамов Николай Дмитриевич", "last_name": "Абрамов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Николай", "rank_short": "ефр.", "short_name": "ефр. Абрамов Н.Д.", "unit_short": "2 рота", "middle_name": "Дмитриевич", "personnel_number": "С-01020"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [{"id": 6, "kind": "rifle", "name": "Учебный автомат", "owner_id": 7, "is_active": true, "serial_number": "TEST-7", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 7, "position": "заместитель командира взвода", "full_name": "Жданов Кирилл Кириллович", "last_name": "Жданов", "rank_name": "старшина", "seniority": 60, "first_name": "Кирилл", "rank_short": "ст-на", "short_name": "ст-на Жданов К.К.", "unit_short": "ТС", "middle_name": "Кириллович", "personnel_number": "Т-0007"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [{"id": 36, "kind": "rifle", "name": "Учебный автомат", "owner_id": 38, "is_active": true, "serial_number": "TEST-38", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 38, "position": "командир отделения", "full_name": "Лукин Иван Викторович", "last_name": "Лукин", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Иван", "rank_short": "ефр.", "short_name": "ефр. Лукин И.В.", "unit_short": "УС", "middle_name": "Викторович", "personnel_number": "Т-0038"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [{"id": 52, "kind": "rifle", "name": "Учебный автомат", "owner_id": 54, "is_active": true, "serial_number": "TEST-54", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 54, "position": "стрелок", "full_name": "Бобров Фёдор Николаевич", "last_name": "Бобров", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Фёдор", "rank_short": "ефр.", "short_name": "ефр. Бобров Ф.Н.", "unit_short": "2 рота", "middle_name": "Николаевич", "personnel_number": "С-01014"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [{"id": 39, "kind": "rifle", "name": "Учебный автомат", "owner_id": 41, "is_active": true, "serial_number": "TEST-41", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 41, "position": "стрелок", "full_name": "Зотов Евгений Олегович", "last_name": "Зотов", "rank_name": "рядовой", "seniority": 10, "first_name": "Евгений", "rank_short": "р-й", "short_name": "р-й Зотов Е.О.", "unit_short": "1 рота", "middle_name": "Олегович", "personnel_number": "С-01001"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-17", "totalAssigned": 12}	2026-09-17	2026-09-18
1520	5	1	2026-10-01 10:00:00+07	2026-10-02 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.204165+07	2026-09-20 19:05:23.204165+07	\N	\N	\N	\N	\N	2026-10-01
362	2	1	2026-09-12 10:30:00+07	2026-09-13 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.94488+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-12
363	2	1	2026-09-13 10:30:00+07	2026-09-14 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.95123+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-13
364	2	1	2026-09-14 10:30:00+07	2026-09-15 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.957383+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-14
1521	5	1	2026-10-02 10:00:00+07	2026-10-03 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.283467+07	2026-09-20 19:05:23.283467+07	\N	\N	\N	\N	\N	2026-10-02
1522	5	1	2026-10-03 10:00:00+07	2026-10-04 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.364147+07	2026-09-20 19:05:23.364147+07	\N	\N	\N	\N	\N	2026-10-03
372	2	1	2026-09-22 10:30:00+07	2026-09-23 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.003912+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-22
373	2	1	2026-09-23 10:30:00+07	2026-09-24 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.009928+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-23
374	2	1	2026-09-24 10:30:00+07	2026-09-25 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.015682+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-24
375	2	1	2026-09-25 10:30:00+07	2026-09-26 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.021402+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-25
379	2	1	2026-09-29 10:30:00+07	2026-09-30 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.044988+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-29
1523	5	1	2026-10-04 10:00:00+07	2026-10-05 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.364147+07	2026-09-20 19:05:23.364147+07	\N	\N	\N	\N	\N	2026-10-04
347	1	1	2026-09-18 17:30:00+07	2026-09-22 17:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.78681+07	2026-09-13 11:39:43.422909+07	1	2026-09-13 11:39:43.422909+07	{"duty": {"id": 347, "note": null, "status": "approved", "ends_at": "2026-09-22T10:30:00.000Z", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-18T10:30:00.000Z", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [{"id": 121, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 123, "is_active": true, "serial_number": "TEST-123", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 123, "position": "командир взвода", "full_name": "Цветков Борис Романович", "last_name": "Цветков", "rank_name": "лейтенант", "seniority": 100, "first_name": "Борис", "rank_short": "л-т", "short_name": "л-т Цветков Б.Р.", "unit_short": "ТС", "middle_name": "Романович", "personnel_number": "С-01083"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [{"id": 122, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 124, "is_active": true, "serial_number": "TEST-124", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 124, "position": "командир взвода", "full_name": "Бобров Игорь Игоревич", "last_name": "Бобров", "rank_name": "лейтенант", "seniority": 100, "first_name": "Игорь", "rank_short": "л-т", "short_name": "л-т Бобров И.И.", "unit_short": "УС", "middle_name": "Игоревич", "personnel_number": "С-01084"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [{"id": 94, "kind": "rifle", "name": "Учебный автомат", "owner_id": 96, "is_active": true, "serial_number": "TEST-96", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 96, "position": "техник", "full_name": "Зотов Николай Дмитриевич", "last_name": "Зотов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Николай", "rank_short": "пр-к", "short_name": "пр-к Зотов Н.Д.", "unit_short": "УС", "middle_name": "Дмитриевич", "personnel_number": "С-01056"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [{"id": 25, "kind": "rifle", "name": "Учебный автомат", "owner_id": 27, "is_active": true, "serial_number": "TEST-27", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 27, "position": "радиотелефонист", "full_name": "Яковлев Олег Григорьевич", "last_name": "Яковлев", "rank_name": "младший сержант", "seniority": 30, "first_name": "Олег", "rank_short": "мл. с-т", "short_name": "мл. с-т Яковлев О.Г.", "unit_short": "ТС", "middle_name": "Григорьевич", "personnel_number": "Т-0027"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [{"id": 17, "kind": "rifle", "name": "Учебный автомат", "owner_id": 19, "is_active": true, "serial_number": "TEST-19", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 19, "position": "радиотелефонист", "full_name": "Ушаков Григорий Кириллович", "last_name": "Ушаков", "rank_name": "старшина", "seniority": 60, "first_name": "Григорий", "rank_short": "ст-на", "short_name": "ст-на Ушаков Г.К.", "unit_short": "ТС", "middle_name": "Кириллович", "personnel_number": "Т-0019"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [{"id": 24, "kind": "rifle", "name": "Учебный автомат", "owner_id": 26, "is_active": true, "serial_number": "TEST-26", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 26, "position": "механик", "full_name": "Юдин Николай Викторович", "last_name": "Юдин", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Николай", "rank_short": "ефр.", "short_name": "ефр. Юдин Н.В.", "unit_short": "УС", "middle_name": "Викторович", "personnel_number": "Т-0026"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [{"id": 23, "kind": "rifle", "name": "Учебный автомат", "owner_id": 25, "is_active": true, "serial_number": "TEST-25", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 25, "position": "водитель", "full_name": "Щукин Михаил Борисович", "last_name": "Щукин", "rank_name": "рядовой", "seniority": 10, "first_name": "Михаил", "rank_short": "р-й", "short_name": "р-й Щукин М.Б.", "unit_short": "2 рота", "middle_name": "Борисович", "personnel_number": "Т-0025"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [{"id": 3, "kind": "rifle", "name": "Учебный автомат", "owner_id": 4, "is_active": true, "serial_number": "TEST-4", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 4, "position": "оператор", "full_name": "Гусев Дмитрий Дмитриевич", "last_name": "Гусев", "rank_name": "младший сержант", "seniority": 30, "first_name": "Дмитрий", "rank_short": "мл. с-т", "short_name": "мл. с-т Гусев Д.Д.", "unit_short": "1 рота", "middle_name": "Дмитриевич", "personnel_number": "Т-0004"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}	{"dutyType": {"code": "OO", "name": "Дежурная смена «Охрана и оборона»"}, "sections": [{"duty": {"id": 347, "note": null, "status": "approved", "ends_at": "2026-09-22T10:30:00.000Z", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-18T10:30:00.000Z", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [{"id": 121, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 123, "is_active": true, "serial_number": "TEST-123", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 123, "position": "командир взвода", "full_name": "Цветков Борис Романович", "last_name": "Цветков", "rank_name": "лейтенант", "seniority": 100, "first_name": "Борис", "rank_short": "л-т", "short_name": "л-т Цветков Б.Р.", "unit_short": "ТС", "middle_name": "Романович", "personnel_number": "С-01083"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [{"id": 122, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 124, "is_active": true, "serial_number": "TEST-124", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 124, "position": "командир взвода", "full_name": "Бобров Игорь Игоревич", "last_name": "Бобров", "rank_name": "лейтенант", "seniority": 100, "first_name": "Игорь", "rank_short": "л-т", "short_name": "л-т Бобров И.И.", "unit_short": "УС", "middle_name": "Игоревич", "personnel_number": "С-01084"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [{"id": 94, "kind": "rifle", "name": "Учебный автомат", "owner_id": 96, "is_active": true, "serial_number": "TEST-96", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 96, "position": "техник", "full_name": "Зотов Николай Дмитриевич", "last_name": "Зотов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Николай", "rank_short": "пр-к", "short_name": "пр-к Зотов Н.Д.", "unit_short": "УС", "middle_name": "Дмитриевич", "personnel_number": "С-01056"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [{"id": 25, "kind": "rifle", "name": "Учебный автомат", "owner_id": 27, "is_active": true, "serial_number": "TEST-27", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 27, "position": "радиотелефонист", "full_name": "Яковлев Олег Григорьевич", "last_name": "Яковлев", "rank_name": "младший сержант", "seniority": 30, "first_name": "Олег", "rank_short": "мл. с-т", "short_name": "мл. с-т Яковлев О.Г.", "unit_short": "ТС", "middle_name": "Григорьевич", "personnel_number": "Т-0027"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [{"id": 17, "kind": "rifle", "name": "Учебный автомат", "owner_id": 19, "is_active": true, "serial_number": "TEST-19", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 19, "position": "радиотелефонист", "full_name": "Ушаков Григорий Кириллович", "last_name": "Ушаков", "rank_name": "старшина", "seniority": 60, "first_name": "Григорий", "rank_short": "ст-на", "short_name": "ст-на Ушаков Г.К.", "unit_short": "ТС", "middle_name": "Кириллович", "personnel_number": "Т-0019"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [{"id": 24, "kind": "rifle", "name": "Учебный автомат", "owner_id": 26, "is_active": true, "serial_number": "TEST-26", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 26, "position": "механик", "full_name": "Юдин Николай Викторович", "last_name": "Юдин", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Николай", "rank_short": "ефр.", "short_name": "ефр. Юдин Н.В.", "unit_short": "УС", "middle_name": "Викторович", "personnel_number": "Т-0026"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [{"id": 23, "kind": "rifle", "name": "Учебный автомат", "owner_id": 25, "is_active": true, "serial_number": "TEST-25", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 25, "position": "водитель", "full_name": "Щукин Михаил Борисович", "last_name": "Щукин", "rank_name": "рядовой", "seniority": 10, "first_name": "Михаил", "rank_short": "р-й", "short_name": "р-й Щукин М.Б.", "unit_short": "2 рота", "middle_name": "Борисович", "personnel_number": "Т-0025"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [{"id": 3, "kind": "rifle", "name": "Учебный автомат", "owner_id": 4, "is_active": true, "serial_number": "TEST-4", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 4, "position": "оператор", "full_name": "Гусев Дмитрий Дмитриевич", "last_name": "Гусев", "rank_name": "младший сержант", "seniority": 30, "first_name": "Дмитрий", "rank_short": "мл. с-т", "short_name": "мл. с-т Гусев Д.Д.", "unit_short": "1 рота", "middle_name": "Дмитриевич", "personnel_number": "Т-0004"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-17", "totalAssigned": 8}	2026-09-17	2026-09-18
1562	1	1	2026-10-02 17:30:00+07	2026-10-06 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:19.242301+07	2026-09-20 19:39:19.242301+07	\N	\N	\N	\N	\N	2026-10-02
392	3	1	2026-09-12 10:00:00+07	2026-09-13 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.11409+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-12
393	3	1	2026-09-13 10:00:00+07	2026-09-14 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.11888+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-13
394	3	1	2026-09-14 10:00:00+07	2026-09-15 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.123922+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-14
395	3	1	2026-09-15 10:00:00+07	2026-09-16 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.12898+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-15
396	3	1	2026-09-16 10:00:00+07	2026-09-17 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.134447+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-16
397	3	1	2026-09-17 10:00:00+07	2026-09-18 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.139715+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-17
398	3	1	2026-09-18 10:00:00+07	2026-09-19 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.145247+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-18
399	3	1	2026-09-19 10:00:00+07	2026-09-20 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.150757+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-19
400	3	1	2026-09-20 10:00:00+07	2026-09-21 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.155683+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-20
401	3	1	2026-09-21 10:00:00+07	2026-09-22 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.16075+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-21
402	3	1	2026-09-22 10:00:00+07	2026-09-23 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.16553+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-22
403	3	1	2026-09-23 10:00:00+07	2026-09-24 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.170384+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-23
404	3	1	2026-09-24 10:00:00+07	2026-09-25 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.17564+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-24
405	3	1	2026-09-25 10:00:00+07	2026-09-26 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.181463+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-25
406	3	1	2026-09-26 10:00:00+07	2026-09-27 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.187026+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-26
407	3	1	2026-09-27 10:00:00+07	2026-09-28 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.192397+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-27
408	3	1	2026-09-28 10:00:00+07	2026-09-29 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.197879+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-28
409	3	1	2026-09-29 10:00:00+07	2026-09-30 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.203382+07	2026-09-11 23:31:51.758064+07	\N	\N	\N	\N	\N	2026-09-29
376	2	1	2026-09-26 10:30:00+07	2026-09-27 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.027215+07	2026-09-11 23:31:51.758064+07	1	2026-09-07 16:00:38.815177+07	\N	\N	\N	2026-09-26
377	2	1	2026-09-27 10:30:00+07	2026-09-28 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.033146+07	2026-09-11 23:31:51.758064+07	1	2026-09-07 16:00:38.815177+07	\N	\N	\N	2026-09-27
378	2	1	2026-09-28 10:30:00+07	2026-09-29 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.039329+07	2026-09-11 23:31:51.758064+07	1	2026-09-07 16:00:38.815177+07	\N	\N	\N	2026-09-28
369	2	1	2026-09-19 10:30:00+07	2026-09-20 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.986865+07	2026-09-11 23:31:51.758064+07	1	2026-09-11 23:31:51.758064+07	\N	\N	\N	2026-09-19
371	2	1	2026-09-21 10:30:00+07	2026-09-22 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.998363+07	2026-09-11 23:31:51.758064+07	1	2026-09-11 23:31:51.758064+07	\N	\N	\N	2026-09-21
370	2	1	2026-09-20 10:30:00+07	2026-09-21 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.992718+07	2026-09-11 23:31:51.758064+07	1	2026-09-11 23:31:51.758064+07	\N	\N	\N	2026-09-20
1024	2	1	2027-01-19 10:30:00+07	2027-01-20 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.822903+07	2026-09-19 14:57:04.822903+07	\N	\N	\N	\N	\N	2027-01-19
1028	2	1	2027-01-23 10:30:00+07	2027-01-24 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:05.454097+07	2026-09-19 14:57:05.454097+07	\N	\N	\N	\N	\N	2027-01-23
1029	2	1	2027-01-24 10:30:00+07	2027-01-25 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:05.458976+07	2026-09-19 14:57:05.458976+07	\N	\N	\N	\N	\N	2027-01-24
1030	2	1	2027-01-25 10:30:00+07	2027-01-26 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:05.460796+07	2026-09-19 14:57:05.460796+07	\N	\N	\N	\N	\N	2027-01-25
1050	3	1	2027-01-13 10:00:00+07	2027-01-14 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:08.880431+07	2026-09-19 14:57:08.880431+07	\N	\N	\N	\N	\N	2027-01-13
1053	3	1	2027-01-16 10:00:00+07	2027-01-17 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.170441+07	2026-09-19 14:57:09.170441+07	\N	\N	\N	\N	\N	2027-01-16
1054	3	1	2027-01-17 10:00:00+07	2027-01-18 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.171963+07	2026-09-19 14:57:09.171963+07	\N	\N	\N	\N	\N	2027-01-17
1055	3	1	2027-01-18 10:00:00+07	2027-01-19 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.173109+07	2026-09-19 14:57:09.173109+07	\N	\N	\N	\N	\N	2027-01-18
1058	3	1	2027-01-21 10:00:00+07	2027-01-22 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.569694+07	2026-09-19 14:57:09.569694+07	\N	\N	\N	\N	\N	2027-01-21
1066	3	1	2027-01-29 10:00:00+07	2027-01-30 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.27523+07	2026-09-19 14:57:10.27523+07	\N	\N	\N	\N	\N	2027-01-29
1067	3	1	2027-01-30 10:00:00+07	2027-01-31 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.408634+07	2026-09-19 14:57:10.408634+07	\N	\N	\N	\N	\N	2027-01-30
1068	3	1	2027-01-31 10:00:00+07	2027-02-01 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.411571+07	2026-09-19 14:57:10.411571+07	\N	\N	\N	\N	\N	2027-01-31
1069	3	1	2027-02-01 10:00:00+07	2027-02-02 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.415094+07	2026-09-19 14:57:10.415094+07	\N	\N	\N	\N	\N	2027-02-01
1130	2	1	2026-11-03 10:30:00+07	2026-11-04 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:44.470632+07	2026-09-19 15:01:44.470632+07	\N	\N	\N	\N	\N	2026-11-03
1131	2	1	2026-11-04 10:30:00+07	2026-11-05 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:44.632741+07	2026-09-19 15:01:44.632741+07	\N	\N	\N	\N	\N	2026-11-04
1132	2	1	2026-11-05 10:30:00+07	2026-11-06 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:44.696335+07	2026-09-19 15:01:44.696335+07	\N	\N	\N	\N	\N	2026-11-05
1140	2	1	2026-11-13 10:30:00+07	2026-11-14 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.792367+07	2026-09-19 15:01:45.792367+07	\N	\N	\N	\N	\N	2026-11-13
1151	2	1	2026-11-24 10:30:00+07	2026-11-25 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.226212+07	2026-09-19 15:01:47.226212+07	\N	\N	\N	\N	\N	2026-11-24
1153	2	1	2026-11-26 10:30:00+07	2026-11-27 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.444045+07	2026-09-19 15:01:47.444045+07	\N	\N	\N	\N	\N	2026-11-26
1161	2	1	2027-02-04 10:30:00+07	2027-02-05 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:48.755028+07	2026-09-19 15:01:48.755028+07	\N	\N	\N	\N	\N	2027-02-04
1174	2	1	2027-02-17 10:30:00+07	2027-02-18 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:50.978508+07	2026-09-19 15:01:50.978508+07	\N	\N	\N	\N	\N	2027-02-17
1177	2	1	2027-02-20 10:30:00+07	2027-02-21 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:51.518515+07	2026-09-19 15:01:51.518515+07	\N	\N	\N	\N	\N	2027-02-20
1178	2	1	2027-02-21 10:30:00+07	2027-02-22 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:51.526435+07	2026-09-19 15:01:51.526435+07	\N	\N	\N	\N	\N	2027-02-21
1179	2	1	2027-02-22 10:30:00+07	2027-02-23 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:51.527635+07	2026-09-19 15:01:51.527635+07	\N	\N	\N	\N	\N	2027-02-22
1183	2	1	2027-02-26 10:30:00+07	2027-02-27 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.534357+07	2026-09-19 15:01:52.534357+07	\N	\N	\N	\N	\N	2027-02-26
1524	5	1	2026-10-05 10:00:00+07	2026-10-06 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.364147+07	2026-09-20 19:05:23.364147+07	\N	\N	\N	\N	\N	2026-10-05
1525	5	1	2026-10-06 10:00:00+07	2026-10-07 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.495449+07	2026-09-20 19:05:23.495449+07	\N	\N	\N	\N	\N	2026-10-06
1526	5	1	2026-10-07 10:00:00+07	2026-10-08 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.582335+07	2026-09-20 19:05:23.582335+07	\N	\N	\N	\N	\N	2026-10-07
344	1	1	2026-09-08 17:30:00+07	2026-09-11 17:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.764608+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 344, "note": null, "status": "draft", "ends_at": "2026-09-11T17:30:00+07:00", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-08T17:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [], "employee": {"id": 114, "full_name": "Бобров Николай Дмитриевич", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [], "employee": {"id": 115, "full_name": "Абрамов Тимур Тимурович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [], "employee": {"id": 93, "full_name": "Цветков Роман Кириллович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [], "employee": {"id": 6, "full_name": "Ершов Иван Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [], "employee": {"id": 29, "full_name": "Баранов Роман Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [], "employee": {"id": 36, "full_name": "Исаев Дмитрий Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [], "employee": {"id": 7, "full_name": "Жданов Кирилл Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}	\N	2026-09-07	2026-09-08
345	1	1	2026-09-11 17:30:00+07	2026-09-15 17:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.772172+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 345, "note": null, "status": "draft", "ends_at": "2026-09-15T17:30:00+07:00", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-11T17:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [], "employee": {"id": 117, "full_name": "Панкратов Кирилл Борисович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [], "employee": {"id": 118, "full_name": "Цветков Павел Павлович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [], "employee": {"id": 94, "full_name": "Бобров Александр Александрович", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [], "employee": {"id": 5, "full_name": "Данилов Евгений Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [], "employee": {"id": 39, "full_name": "Медведев Кирилл Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [], "employee": {"id": 17, "full_name": "Сафонов Борис Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}	\N	2026-09-08	2026-09-11
357	2	1	2026-09-07 10:30:00+07	2026-09-08 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.914829+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 357, "note": null, "status": "draft", "ends_at": "2026-09-08T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-07T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 107, "full_name": "Панкратов Олег Юрьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 108, "full_name": "Цветков Фёдор Николаевич", "rank_name": "старший прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 85, "full_name": "Абрамов Максим Максимович", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 88, "full_name": "Цветков Игорь Игоревич", "rank_name": "старшина", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 67, "full_name": "Панкратов Максим Максимович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 69, "full_name": "Бобров Борис Романович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 58, "full_name": "Цветков Александр Александрович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 52, "full_name": "Панкратов Игорь Игоревич", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 54, "full_name": "Бобров Фёдор Николаевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 55, "full_name": "Абрамов Геннадий Геннадьевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 17, "full_name": "Сафонов Борис Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	\N	2026-09-04	2026-09-07
1527	5	1	2026-10-08 10:00:00+07	2026-10-09 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.666764+07	2026-09-20 19:05:23.666764+07	\N	\N	\N	\N	\N	2026-10-08
1528	5	1	2026-10-09 10:00:00+07	2026-10-10 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.746601+07	2026-09-20 19:05:23.746601+07	\N	\N	\N	\N	\N	2026-10-09
1529	5	1	2026-10-10 10:00:00+07	2026-10-11 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.821376+07	2026-09-20 19:05:23.821376+07	\N	\N	\N	\N	\N	2026-10-10
1530	5	1	2026-10-11 10:00:00+07	2026-10-12 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.821376+07	2026-09-20 19:05:23.821376+07	\N	\N	\N	\N	\N	2026-10-11
1531	5	1	2026-10-12 10:00:00+07	2026-10-13 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.821376+07	2026-09-20 19:05:23.821376+07	\N	\N	\N	\N	\N	2026-10-12
1532	5	1	2026-10-13 10:00:00+07	2026-10-14 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:23.949355+07	2026-09-20 19:05:23.949355+07	\N	\N	\N	\N	\N	2026-10-13
1533	5	1	2026-10-14 10:00:00+07	2026-10-15 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.025907+07	2026-09-20 19:05:24.025907+07	\N	\N	\N	\N	\N	2026-10-14
1031	2	1	2027-01-26 10:30:00+07	2027-01-27 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:05.929032+07	2026-09-19 14:57:05.929032+07	\N	\N	\N	\N	\N	2027-01-26
1052	3	1	2027-01-15 10:00:00+07	2027-01-16 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.046171+07	2026-09-19 14:57:09.046171+07	\N	\N	\N	\N	\N	2027-01-15
1065	3	1	2027-01-28 10:00:00+07	2027-01-29 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.188203+07	2026-09-19 14:57:10.188203+07	\N	\N	\N	\N	\N	2027-01-28
1133	2	1	2026-11-06 10:30:00+07	2026-11-07 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:44.898832+07	2026-09-19 15:01:44.898832+07	\N	\N	\N	\N	\N	2026-11-06
1134	2	1	2026-11-07 10:30:00+07	2026-11-08 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.084546+07	2026-09-19 15:01:45.084546+07	\N	\N	\N	\N	\N	2026-11-07
1135	2	1	2026-11-08 10:30:00+07	2026-11-09 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.092841+07	2026-09-19 15:01:45.092841+07	\N	\N	\N	\N	\N	2026-11-08
1136	2	1	2026-11-09 10:30:00+07	2026-11-10 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.094135+07	2026-09-19 15:01:45.094135+07	\N	\N	\N	\N	\N	2026-11-09
1159	2	1	2027-02-02 10:30:00+07	2027-02-03 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:48.465312+07	2026-09-19 15:01:48.465312+07	\N	\N	\N	\N	\N	2027-02-02
1169	2	1	2027-02-12 10:30:00+07	2027-02-13 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:50.084038+07	2026-09-19 15:01:50.084038+07	\N	\N	\N	\N	\N	2027-02-12
1170	2	1	2027-02-13 10:30:00+07	2027-02-14 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:50.325882+07	2026-09-19 15:01:50.325882+07	\N	\N	\N	\N	\N	2027-02-13
1171	2	1	2027-02-14 10:30:00+07	2027-02-15 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:50.333946+07	2026-09-19 15:01:50.333946+07	\N	\N	\N	\N	\N	2027-02-14
1172	2	1	2027-02-15 10:30:00+07	2027-02-16 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:50.335527+07	2026-09-19 15:01:50.335527+07	\N	\N	\N	\N	\N	2027-02-15
1184	2	1	2027-02-27 10:30:00+07	2027-02-28 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.781038+07	2026-09-19 15:01:52.781038+07	\N	\N	\N	\N	\N	2027-02-27
1185	2	1	2027-02-28 10:30:00+07	2027-03-01 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.788986+07	2026-09-19 15:01:52.788986+07	\N	\N	\N	\N	\N	2027-02-28
1186	2	1	2027-03-01 10:30:00+07	2027-03-02 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.790206+07	2026-09-19 15:01:52.790206+07	\N	\N	\N	\N	\N	2027-03-01
1449	2	1	2026-12-01 10:30:00+07	2026-12-02 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:07.594983+07	2026-09-19 15:20:07.594983+07	\N	\N	\N	\N	\N	2026-12-01
1450	2	1	2026-12-02 10:30:00+07	2026-12-03 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:07.706585+07	2026-09-19 15:20:07.706585+07	\N	\N	\N	\N	\N	2026-12-02
1451	2	1	2026-12-03 10:30:00+07	2026-12-04 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:07.812683+07	2026-09-19 15:20:07.812683+07	\N	\N	\N	\N	\N	2026-12-03
1457	2	1	2026-12-09 10:30:00+07	2026-12-10 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:08.619389+07	2026-09-19 15:20:08.619389+07	\N	\N	\N	\N	\N	2026-12-09
1459	2	1	2026-12-11 10:30:00+07	2026-12-12 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:08.849861+07	2026-09-19 15:20:08.849861+07	\N	\N	\N	\N	\N	2026-12-11
1460	2	1	2026-12-12 10:30:00+07	2026-12-13 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.049881+07	2026-09-19 15:20:09.049881+07	\N	\N	\N	\N	\N	2026-12-12
1461	2	1	2026-12-13 10:30:00+07	2026-12-14 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.05791+07	2026-09-19 15:20:09.05791+07	\N	\N	\N	\N	\N	2026-12-13
1462	2	1	2026-12-14 10:30:00+07	2026-12-15 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.059126+07	2026-09-19 15:20:09.059126+07	\N	\N	\N	\N	\N	2026-12-14
1465	2	1	2026-12-17 10:30:00+07	2026-12-18 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.697086+07	2026-09-19 15:20:09.697086+07	\N	\N	\N	\N	\N	2026-12-17
1482	3	1	2026-10-06 10:00:00+07	2026-10-07 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.042477+07	2026-09-19 16:45:51.042477+07	\N	\N	\N	\N	\N	2026-10-06
359	2	1	2026-09-09 10:30:00+07	2026-09-10 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.926698+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 359, "note": null, "status": "draft", "ends_at": "2026-09-10T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-09T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 118, "full_name": "Цветков Павел Павлович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 119, "full_name": "Бобров Юрий Евгеньевич", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 89, "full_name": "Бобров Олег Юрьевич", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 5, "full_name": "Данилов Евгений Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 47, "full_name": "Панкратов Юрий Евгеньевич", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 49, "full_name": "Бобров Максим Максимович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 66, "full_name": "Зотов Дмитрий Фёдорович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 25, "full_name": "Щукин Михаил Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 54, "full_name": "Бобров Фёдор Николаевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	\N	2026-09-08	2026-09-09
360	2	1	2026-09-10 10:30:00+07	2026-09-11 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.933026+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 360, "note": null, "status": "draft", "ends_at": "2026-09-11T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-10T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 103, "full_name": "Цветков Максим Максимович", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 123, "full_name": "Цветков Борис Романович", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 91, "full_name": "Зотов Геннадий Геннадьевич", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 70, "full_name": "Абрамов Игорь Игоревич", "rank_name": "младший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 53, "full_name": "Цветков Олег Юрьевич", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 51, "full_name": "Зотов Борис Романович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 58, "full_name": "Цветков Александр Александрович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 52, "full_name": "Панкратов Игорь Игоревич", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 2, "full_name": "Белов Виктор Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 12, "full_name": "Морозов Павел Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 15, "full_name": "Панов Тимофей Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 24, "full_name": "Шилов Леонид Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	\N	2026-09-08	2026-09-10
361	2	1	2026-09-11 10:30:00+07	2026-09-12 10:30:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:53.939142+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 361, "note": null, "status": "draft", "ends_at": "2026-09-12T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-11T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 124, "full_name": "Бобров Игорь Игоревич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 125, "full_name": "Абрамов Олег Юрьевич", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 71, "full_name": "Зотов Олег Юрьевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 72, "full_name": "Панкратов Фёдор Николаевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 67, "full_name": "Панкратов Максим Максимович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 69, "full_name": "Бобров Борис Романович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 60, "full_name": "Абрамов Николай Дмитриевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 64, "full_name": "Бобров Павел Павлович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 19, "full_name": "Ушаков Григорий Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 25, "full_name": "Щукин Михаил Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 26, "full_name": "Юдин Николай Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 37, "full_name": "Крылов Евгений Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	\N	2026-09-08	2026-09-11
387	3	1	2026-09-07 10:00:00+07	2026-09-08 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.088651+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 387, "note": null, "status": "draft", "ends_at": "2026-09-08T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-07T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 127, "full_name": "Панкратов Геннадий Геннадьевич", "rank_name": "старший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 129, "full_name": "Бобров Роман Кириллович", "rank_name": "старший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 130, "full_name": "Абрамов Александр Александрович", "rank_name": "старший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 91, "full_name": "Зотов Геннадий Геннадьевич", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 39, "full_name": "Медведев Кирилл Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	\N	2026-09-04	2026-09-07
388	3	1	2026-09-08 10:00:00+07	2026-09-09 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.093422+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 388, "note": null, "status": "draft", "ends_at": "2026-09-09T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-08T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 138, "full_name": "Цветков Дмитрий Фёдорович", "rank_name": "капитан", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 132, "full_name": "Панкратов Николай Дмитриевич", "rank_name": "старший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 133, "full_name": "Цветков Тимур Тимурович", "rank_name": "старший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 70, "full_name": "Абрамов Игорь Игоревич", "rank_name": "младший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 60, "full_name": "Абрамов Николай Дмитриевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	\N	2026-09-07	2026-09-08
389	3	1	2026-09-09 10:00:00+07	2026-09-10 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.098231+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 389, "note": null, "status": "draft", "ends_at": "2026-09-10T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-09T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 135, "full_name": "Абрамов Кирилл Борисович", "rank_name": "старший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 136, "full_name": "Зотов Павел Павлович", "rank_name": "старший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 137, "full_name": "Панкратов Юрий Евгеньевич", "rank_name": "капитан", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 72, "full_name": "Панкратов Фёдор Николаевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 73, "full_name": "Цветков Геннадий Геннадьевич", "rank_name": "сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	\N	2026-09-08	2026-09-09
1534	5	1	2026-10-15 10:00:00+07	2026-10-16 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.102422+07	2026-09-20 19:05:24.102422+07	\N	\N	\N	\N	\N	2026-10-15
1535	5	1	2026-10-16 10:00:00+07	2026-10-17 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.178346+07	2026-09-20 19:05:24.178346+07	\N	\N	\N	\N	\N	2026-10-16
1536	5	1	2026-10-17 10:00:00+07	2026-10-18 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.255157+07	2026-09-20 19:05:24.255157+07	\N	\N	\N	\N	\N	2026-10-17
1537	5	1	2026-10-18 10:00:00+07	2026-10-19 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.255157+07	2026-09-20 19:05:24.255157+07	\N	\N	\N	\N	\N	2026-10-18
1538	5	1	2026-10-19 10:00:00+07	2026-10-20 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.255157+07	2026-09-20 19:05:24.255157+07	\N	\N	\N	\N	\N	2026-10-19
1539	5	1	2026-10-20 10:00:00+07	2026-10-21 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.386167+07	2026-09-20 19:05:24.386167+07	\N	\N	\N	\N	\N	2026-10-20
390	3	1	2026-09-10 10:00:00+07	2026-09-11 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.103609+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 390, "note": null, "status": "draft", "ends_at": "2026-09-11T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-10T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 138, "full_name": "Цветков Дмитрий Фёдорович", "rank_name": "капитан", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 139, "full_name": "Бобров Максим Максимович", "rank_name": "капитан", "unit_short": "в/ч 00000"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 142, "full_name": "Панкратов Игорь Игоревич", "rank_name": "капитан", "unit_short": "в/ч 00000"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 75, "full_name": "Абрамов Роман Кириллович", "rank_name": "сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 76, "full_name": "Зотов Александр Александрович", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	\N	2026-09-08	2026-09-10
391	3	1	2026-09-11 10:00:00+07	2026-09-12 10:00:00+07	draft	\N	\N	\N	\N	2026-09-07 14:47:54.108795+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 391, "note": null, "status": "draft", "ends_at": "2026-09-12T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-11T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 143, "full_name": "Цветков Олег Юрьевич", "rank_name": "капитан", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 9, "full_name": "Ильин Михаил Михайлович", "rank_name": "лейтенант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 34, "full_name": "Жуков Виктор Николаевич", "rank_name": "капитан", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 85, "full_name": "Абрамов Максим Максимович", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 88, "full_name": "Цветков Игорь Игоревич", "rank_name": "старшина", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	\N	2026-09-08	2026-09-11
601	2	1	2026-12-31 10:30:00+07	2027-01-01 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:50:53.890885+07	2026-09-19 14:50:53.890885+07	\N	\N	\N	\N	\N	2026-12-31
1006	2	1	2027-01-01 10:30:00+07	2027-01-02 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.292248+07	2026-09-19 14:56:59.292248+07	\N	\N	\N	\N	\N	2027-01-01
1007	2	1	2027-01-02 10:30:00+07	2027-01-03 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.301466+07	2026-09-19 14:56:59.301466+07	\N	\N	\N	\N	\N	2027-01-02
1008	2	1	2027-01-03 10:30:00+07	2027-01-04 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.302752+07	2026-09-19 14:56:59.302752+07	\N	\N	\N	\N	\N	2027-01-03
1009	2	1	2027-01-04 10:30:00+07	2027-01-05 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.303935+07	2026-09-19 14:56:59.303935+07	\N	\N	\N	\N	\N	2027-01-04
1010	2	1	2027-01-05 10:30:00+07	2027-01-06 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.305132+07	2026-09-19 14:56:59.305132+07	\N	\N	\N	\N	\N	2027-01-05
1011	2	1	2027-01-06 10:30:00+07	2027-01-07 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.306267+07	2026-09-19 14:56:59.306267+07	\N	\N	\N	\N	\N	2027-01-06
1012	2	1	2027-01-07 10:30:00+07	2027-01-08 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.30729+07	2026-09-19 14:56:59.30729+07	\N	\N	\N	\N	\N	2027-01-07
1013	2	1	2027-01-08 10:30:00+07	2027-01-09 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.308211+07	2026-09-19 14:56:59.308211+07	\N	\N	\N	\N	\N	2027-01-08
1014	2	1	2027-01-09 10:30:00+07	2027-01-10 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.309124+07	2026-09-19 14:56:59.309124+07	\N	\N	\N	\N	\N	2027-01-09
1015	2	1	2027-01-10 10:30:00+07	2027-01-11 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.310045+07	2026-09-19 14:56:59.310045+07	\N	\N	\N	\N	\N	2027-01-10
1016	2	1	2027-01-11 10:30:00+07	2027-01-12 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:56:59.310999+07	2026-09-19 14:56:59.310999+07	\N	\N	\N	\N	\N	2027-01-11
1025	2	1	2027-01-20 10:30:00+07	2027-01-21 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.958238+07	2026-09-19 14:57:04.958238+07	\N	\N	\N	\N	\N	2027-01-20
1027	2	1	2027-01-22 10:30:00+07	2027-01-23 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:05.231835+07	2026-09-19 14:57:05.231835+07	\N	\N	\N	\N	\N	2027-01-22
1032	2	1	2027-01-27 10:30:00+07	2027-01-28 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:06.063521+07	2026-09-19 14:57:06.063521+07	\N	\N	\N	\N	\N	2027-01-27
1034	2	1	2027-01-29 10:30:00+07	2027-01-30 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:06.338813+07	2026-09-19 14:57:06.338813+07	\N	\N	\N	\N	\N	2027-01-29
1044	3	1	2027-01-07 10:00:00+07	2027-01-08 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.17544+07	2026-09-19 14:57:07.17544+07	\N	\N	\N	\N	\N	2027-01-07
1045	3	1	2027-01-08 10:00:00+07	2027-01-09 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.177359+07	2026-09-19 14:57:07.177359+07	\N	\N	\N	\N	\N	2027-01-08
1046	3	1	2027-01-09 10:00:00+07	2027-01-10 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.178241+07	2026-09-19 14:57:07.178241+07	\N	\N	\N	\N	\N	2027-01-09
1047	3	1	2027-01-10 10:00:00+07	2027-01-11 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.179334+07	2026-09-19 14:57:07.179334+07	\N	\N	\N	\N	\N	2027-01-10
1048	3	1	2027-01-11 10:00:00+07	2027-01-12 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.181136+07	2026-09-19 14:57:07.181136+07	\N	\N	\N	\N	\N	2027-01-11
1051	3	1	2027-01-14 10:00:00+07	2027-01-15 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:08.963964+07	2026-09-19 14:57:08.963964+07	\N	\N	\N	\N	\N	2027-01-14
1057	3	1	2027-01-20 10:00:00+07	2027-01-21 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.486292+07	2026-09-19 14:57:09.486292+07	\N	\N	\N	\N	\N	2027-01-20
1060	3	1	2027-01-23 10:00:00+07	2027-01-24 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.785254+07	2026-09-19 14:57:09.785254+07	\N	\N	\N	\N	\N	2027-01-23
1061	3	1	2027-01-24 10:00:00+07	2027-01-25 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.786341+07	2026-09-19 14:57:09.786341+07	\N	\N	\N	\N	\N	2027-01-24
1062	3	1	2027-01-25 10:00:00+07	2027-01-26 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.787276+07	2026-09-19 14:57:09.787276+07	\N	\N	\N	\N	\N	2027-01-25
1138	2	1	2026-11-11 10:30:00+07	2026-11-12 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.559636+07	2026-09-19 15:01:45.559636+07	\N	\N	\N	\N	\N	2026-11-11
1145	2	1	2026-11-18 10:30:00+07	2026-11-19 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.458462+07	2026-09-19 15:01:46.458462+07	\N	\N	\N	\N	\N	2026-11-18
1147	2	1	2026-11-20 10:30:00+07	2026-11-21 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.658306+07	2026-09-19 15:01:46.658306+07	\N	\N	\N	\N	\N	2026-11-20
1148	2	1	2026-11-21 10:30:00+07	2026-11-22 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.842332+07	2026-09-19 15:01:46.842332+07	\N	\N	\N	\N	\N	2026-11-21
1149	2	1	2026-11-22 10:30:00+07	2026-11-23 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.850464+07	2026-09-19 15:01:46.850464+07	\N	\N	\N	\N	\N	2026-11-22
1150	2	1	2026-11-23 10:30:00+07	2026-11-24 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:46.851777+07	2026-09-19 15:01:46.851777+07	\N	\N	\N	\N	\N	2026-11-23
1155	2	1	2026-11-28 10:30:00+07	2026-11-29 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.742544+07	2026-09-19 15:01:47.742544+07	\N	\N	\N	\N	\N	2026-11-28
1156	2	1	2026-11-29 10:30:00+07	2026-11-30 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.750718+07	2026-09-19 15:01:47.750718+07	\N	\N	\N	\N	\N	2026-11-29
1157	2	1	2026-11-30 10:30:00+07	2026-12-01 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:47.751978+07	2026-09-19 15:01:47.751978+07	\N	\N	\N	\N	\N	2026-11-30
1180	2	1	2027-02-23 10:30:00+07	2027-02-24 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.084393+07	2026-09-19 15:01:52.084393+07	\N	\N	\N	\N	\N	2027-02-23
1181	2	1	2027-02-24 10:30:00+07	2027-02-25 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.092294+07	2026-09-19 15:01:52.092294+07	\N	\N	\N	\N	\N	2027-02-24
1452	2	1	2026-12-04 10:30:00+07	2026-12-05 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:07.918886+07	2026-09-19 15:20:07.918886+07	\N	\N	\N	\N	\N	2026-12-04
1453	2	1	2026-12-05 10:30:00+07	2026-12-06 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:08.105805+07	2026-09-19 15:20:08.105805+07	\N	\N	\N	\N	\N	2026-12-05
1454	2	1	2026-12-06 10:30:00+07	2026-12-07 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:08.113722+07	2026-09-19 15:20:08.113722+07	\N	\N	\N	\N	\N	2026-12-06
1455	2	1	2026-12-07 10:30:00+07	2026-12-08 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:08.114754+07	2026-09-19 15:20:08.114754+07	\N	\N	\N	\N	\N	2026-12-07
1464	2	1	2026-12-16 10:30:00+07	2026-12-17 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:09.569074+07	2026-09-19 15:20:09.569074+07	\N	\N	\N	\N	\N	2026-12-16
1470	2	1	2026-12-22 10:30:00+07	2026-12-23 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.494696+07	2026-09-19 15:20:10.494696+07	\N	\N	\N	\N	\N	2026-12-22
1472	2	1	2026-12-24 10:30:00+07	2026-12-25 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.757529+07	2026-09-19 15:20:10.757529+07	\N	\N	\N	\N	\N	2026-12-24
1474	2	1	2026-12-26 10:30:00+07	2026-12-27 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:11.111061+07	2026-09-19 15:20:11.111061+07	\N	\N	\N	\N	\N	2026-12-26
1475	2	1	2026-12-27 10:30:00+07	2026-12-28 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:11.118921+07	2026-09-19 15:20:11.118921+07	\N	\N	\N	\N	\N	2026-12-27
1476	2	1	2026-12-28 10:30:00+07	2026-12-29 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:11.120061+07	2026-09-19 15:20:11.120061+07	\N	\N	\N	\N	\N	2026-12-28
1484	3	1	2026-10-08 10:00:00+07	2026-10-09 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.198361+07	2026-09-19 16:45:51.198361+07	\N	\N	\N	\N	\N	2026-10-08
1499	3	1	2026-10-23 10:00:00+07	2026-10-24 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.335273+07	2026-09-19 16:45:52.335273+07	\N	\N	\N	\N	\N	2026-10-23
1503	3	1	2026-10-27 10:00:00+07	2026-10-28 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.646803+07	2026-09-19 16:45:52.646803+07	\N	\N	\N	\N	\N	2026-10-27
1540	5	1	2026-10-21 10:00:00+07	2026-10-22 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.462864+07	2026-09-20 19:05:24.462864+07	\N	\N	\N	\N	\N	2026-10-21
342	1	1	2026-09-01 17:30:00+07	2026-09-04 17:30:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:53.749227+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 342, "note": null, "status": "approved", "ends_at": "2026-09-04T17:30:00+07:00", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-01T17:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [], "employee": {"id": 22, "full_name": "Цветков Иван Николаевич", "rank_name": "капитан", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [], "employee": {"id": 111, "full_name": "Зотов Роман Кириллович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [], "employee": {"id": 8, "full_name": "Зайцев Леонид Леонидович", "rank_name": "прапорщик", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [], "employee": {"id": 2, "full_name": "Белов Виктор Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [], "employee": {"id": 12, "full_name": "Морозов Павел Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [], "employee": {"id": 15, "full_name": "Панов Тимофей Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [], "employee": {"id": 24, "full_name": "Шилов Леонид Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [], "employee": {"id": 25, "full_name": "Щукин Михаил Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}	{"dutyType": {"code": "OO", "name": "Дежурная смена «Охрана и оборона»"}, "sections": [{"duty": {"id": 342, "note": null, "status": "approved", "ends_at": "2026-09-04T17:30:00+07:00", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-01T17:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [], "employee": {"id": 22, "full_name": "Цветков Иван Николаевич", "rank_name": "капитан", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [], "employee": {"id": 111, "full_name": "Зотов Роман Кириллович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [], "employee": {"id": 8, "full_name": "Зайцев Леонид Леонидович", "rank_name": "прапорщик", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [], "employee": {"id": 2, "full_name": "Белов Виктор Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [], "employee": {"id": 12, "full_name": "Морозов Павел Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [], "employee": {"id": 15, "full_name": "Панов Тимофей Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [], "employee": {"id": 24, "full_name": "Шилов Леонид Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [], "employee": {"id": 25, "full_name": "Щукин Михаил Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-08-31", "totalAssigned": 8, "historicalImport": true}	2026-08-31	2026-09-01
343	1	1	2026-09-04 17:30:00+07	2026-09-08 17:30:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:53.758007+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 343, "note": null, "status": "approved", "ends_at": "2026-09-08T17:30:00+07:00", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-04T17:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [], "employee": {"id": 112, "full_name": "Панкратов Александр Александрович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [], "employee": {"id": 113, "full_name": "Цветков Евгений Олегович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [], "employee": {"id": 32, "full_name": "Дроздов Александр Леонидович", "rank_name": "прапорщик", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [], "employee": {"id": 37, "full_name": "Крылов Евгений Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [], "employee": {"id": 19, "full_name": "Ушаков Григорий Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [], "employee": {"id": 26, "full_name": "Юдин Николай Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [], "employee": {"id": 28, "full_name": "Антонов Павел Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [], "employee": {"id": 4, "full_name": "Гусев Дмитрий Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}	{"dutyType": {"code": "OO", "name": "Дежурная смена «Охрана и оборона»"}, "sections": [{"duty": {"id": 343, "note": null, "status": "approved", "ends_at": "2026-09-08T17:30:00+07:00", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-04T17:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 1}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС"}, "broken": null, "weapons": [], "employee": {"id": 112, "full_name": "Панкратов Александр Александрович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС"}, "broken": null, "weapons": [], "employee": {"id": 113, "full_name": "Цветков Евгений Олегович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР"}, "broken": null, "weapons": [], "employee": {"id": 32, "full_name": "Дроздов Александр Леонидович", "rank_name": "прапорщик", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1"}, "broken": null, "weapons": [], "employee": {"id": 37, "full_name": "Крылов Евгений Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2"}, "broken": null, "weapons": [], "employee": {"id": 19, "full_name": "Ушаков Григорий Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3"}, "broken": null, "weapons": [], "employee": {"id": 26, "full_name": "Юдин Николай Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4"}, "broken": null, "weapons": [], "employee": {"id": 28, "full_name": "Антонов Павел Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5"}, "broken": null, "weapons": [], "employee": {"id": 4, "full_name": "Гусев Дмитрий Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 8, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-03", "totalAssigned": 8, "historicalImport": true}	2026-09-03	2026-09-04
351	2	1	2026-09-01 10:30:00+07	2026-09-02 10:30:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:53.869997+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 351, "note": null, "status": "approved", "ends_at": "2026-09-02T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-01T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 32, "full_name": "Дроздов Александр Леонидович", "rank_name": "прапорщик", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 93, "full_name": "Цветков Роман Кириллович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 28, "full_name": "Антонов Павел Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 29, "full_name": "Баранов Роман Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 36, "full_name": "Исаев Дмитрий Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 37, "full_name": "Крылов Евгений Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 42, "full_name": "Панкратов Николай Дмитриевич", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 19, "full_name": "Ушаков Григорий Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 26, "full_name": "Юдин Николай Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 4, "full_name": "Гусев Дмитрий Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 351, "note": null, "status": "approved", "ends_at": "2026-09-02T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-01T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 32, "full_name": "Дроздов Александр Леонидович", "rank_name": "прапорщик", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 93, "full_name": "Цветков Роман Кириллович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 28, "full_name": "Антонов Павел Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 29, "full_name": "Баранов Роман Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 36, "full_name": "Исаев Дмитрий Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 37, "full_name": "Крылов Евгений Борисович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 42, "full_name": "Панкратов Николай Дмитриевич", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 19, "full_name": "Ушаков Григорий Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 26, "full_name": "Юдин Николай Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 4, "full_name": "Гусев Дмитрий Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-08-31", "totalAssigned": 12, "historicalImport": true}	2026-08-31	2026-09-01
352	2	1	2026-09-02 10:30:00+07	2026-09-03 10:30:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:53.879399+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 352, "note": null, "status": "approved", "ends_at": "2026-09-03T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-02T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 94, "full_name": "Бобров Александр Александрович", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 95, "full_name": "Абрамов Евгений Олегович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 71, "full_name": "Зотов Олег Юрьевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 70, "full_name": "Абрамов Игорь Игоревич", "rank_name": "младший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 43, "full_name": "Цветков Тимур Тимурович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 45, "full_name": "Абрамов Кирилл Борисович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 46, "full_name": "Зотов Павел Павлович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 48, "full_name": "Цветков Дмитрий Фёдорович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 54, "full_name": "Бобров Фёдор Николаевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 55, "full_name": "Абрамов Геннадий Геннадьевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 17, "full_name": "Сафонов Борис Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 352, "note": null, "status": "approved", "ends_at": "2026-09-03T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-02T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 94, "full_name": "Бобров Александр Александрович", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 95, "full_name": "Абрамов Евгений Олегович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 71, "full_name": "Зотов Олег Юрьевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 70, "full_name": "Абрамов Игорь Игоревич", "rank_name": "младший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 43, "full_name": "Цветков Тимур Тимурович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 45, "full_name": "Абрамов Кирилл Борисович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 46, "full_name": "Зотов Павел Павлович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 48, "full_name": "Цветков Дмитрий Фёдорович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 54, "full_name": "Бобров Фёдор Николаевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 55, "full_name": "Абрамов Геннадий Геннадьевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 17, "full_name": "Сафонов Борис Евгеньевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-01", "totalAssigned": 12, "historicalImport": true}	2026-09-01	2026-09-02
1541	5	1	2026-10-22 10:00:00+07	2026-10-23 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.539225+07	2026-09-20 19:05:24.539225+07	\N	\N	\N	\N	\N	2026-10-22
1542	5	1	2026-10-23 10:00:00+07	2026-10-24 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.614874+07	2026-09-20 19:05:24.614874+07	\N	\N	\N	\N	\N	2026-10-23
1543	5	1	2026-10-24 10:00:00+07	2026-10-25 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.691714+07	2026-09-20 19:05:24.691714+07	\N	\N	\N	\N	\N	2026-10-24
1544	5	1	2026-10-25 10:00:00+07	2026-10-26 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.691714+07	2026-09-20 19:05:24.691714+07	\N	\N	\N	\N	\N	2026-10-25
1545	5	1	2026-10-26 10:00:00+07	2026-10-27 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.691714+07	2026-09-20 19:05:24.691714+07	\N	\N	\N	\N	\N	2026-10-26
1546	5	1	2026-10-27 10:00:00+07	2026-10-28 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.824484+07	2026-09-20 19:05:24.824484+07	\N	\N	\N	\N	\N	2026-10-27
1547	5	1	2026-10-28 10:00:00+07	2026-10-29 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.902495+07	2026-09-20 19:05:24.902495+07	\N	\N	\N	\N	\N	2026-10-28
1548	5	1	2026-10-29 10:00:00+07	2026-10-30 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:24.986611+07	2026-09-20 19:05:24.986611+07	\N	\N	\N	\N	\N	2026-10-29
599	2	1	2026-12-29 10:30:00+07	2026-12-30 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:50:53.623866+07	2026-09-19 14:50:53.623866+07	\N	\N	\N	\N	\N	2026-12-29
1017	2	1	2027-01-12 10:30:00+07	2027-01-13 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:03.73217+07	2026-09-19 14:57:03.73217+07	\N	\N	\N	\N	\N	2027-01-12
1019	2	1	2027-01-14 10:30:00+07	2027-01-15 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.004503+07	2026-09-19 14:57:04.004503+07	\N	\N	\N	\N	\N	2027-01-14
1026	2	1	2027-01-21 10:30:00+07	2027-01-22 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:05.093475+07	2026-09-19 14:57:05.093475+07	\N	\N	\N	\N	\N	2027-01-21
1038	3	1	2027-01-01 10:00:00+07	2027-01-02 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.164673+07	2026-09-19 14:57:07.164673+07	\N	\N	\N	\N	\N	2027-01-01
1039	3	1	2027-01-02 10:00:00+07	2027-01-03 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.165817+07	2026-09-19 14:57:07.165817+07	\N	\N	\N	\N	\N	2027-01-02
1040	3	1	2027-01-03 10:00:00+07	2027-01-04 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.166885+07	2026-09-19 14:57:07.166885+07	\N	\N	\N	\N	\N	2027-01-03
1041	3	1	2027-01-04 10:00:00+07	2027-01-05 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.16817+07	2026-09-19 14:57:07.16817+07	\N	\N	\N	\N	\N	2027-01-04
1042	3	1	2027-01-05 10:00:00+07	2027-01-06 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.170727+07	2026-09-19 14:57:07.170727+07	\N	\N	\N	\N	\N	2027-01-05
1043	3	1	2027-01-06 10:00:00+07	2027-01-07 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:07.171987+07	2026-09-19 14:57:07.171987+07	\N	\N	\N	\N	\N	2027-01-06
353	2	1	2026-09-03 10:30:00+07	2026-09-04 10:30:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:53.886234+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 353, "note": null, "status": "approved", "ends_at": "2026-09-04T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-03T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 96, "full_name": "Зотов Николай Дмитриевич", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 97, "full_name": "Панкратов Тимур Тимурович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 73, "full_name": "Цветков Геннадий Геннадьевич", "rank_name": "сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 72, "full_name": "Панкратов Фёдор Николаевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 47, "full_name": "Панкратов Юрий Евгеньевич", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 49, "full_name": "Бобров Максим Максимович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 58, "full_name": "Цветков Александр Александрович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 52, "full_name": "Панкратов Игорь Игоревич", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 6, "full_name": "Ершов Иван Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 36, "full_name": "Исаев Дмитрий Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 7, "full_name": "Жданов Кирилл Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 353, "note": null, "status": "approved", "ends_at": "2026-09-04T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-03T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 96, "full_name": "Зотов Николай Дмитриевич", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 97, "full_name": "Панкратов Тимур Тимурович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 73, "full_name": "Цветков Геннадий Геннадьевич", "rank_name": "сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 72, "full_name": "Панкратов Фёдор Николаевич", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 47, "full_name": "Панкратов Юрий Евгеньевич", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 49, "full_name": "Бобров Максим Максимович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 58, "full_name": "Цветков Александр Александрович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 52, "full_name": "Панкратов Игорь Игоревич", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 6, "full_name": "Ершов Иван Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 36, "full_name": "Исаев Дмитрий Александрович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 7, "full_name": "Жданов Кирилл Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-02", "totalAssigned": 12, "historicalImport": true}	2026-09-02	2026-09-03
354	2	1	2026-09-04 10:30:00+07	2026-09-05 10:30:00+07	approved	\N	1	2026-09-07 15:16:23.152036+07	\N	2026-09-07 14:47:53.893914+07	2026-09-11 23:31:51.793175+07	1	2026-09-07 15:16:23.05336+07	{"duty": {"id": 354, "note": null, "status": "approved", "ends_at": "2026-09-05T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-04T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 99, "full_name": "Бобров Кирилл Борисович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 101, "full_name": "Зотов Юрий Евгеньевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 75, "full_name": "Абрамов Роман Кириллович", "rank_name": "сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 76, "full_name": "Зотов Александр Александрович", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 53, "full_name": "Цветков Олег Юрьевич", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 51, "full_name": "Зотов Борис Романович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 60, "full_name": "Абрамов Николай Дмитриевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 64, "full_name": "Бобров Павел Павлович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 54, "full_name": "Бобров Фёдор Николаевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 354, "note": null, "status": "approved", "ends_at": "2026-09-05T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-04T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 99, "full_name": "Бобров Кирилл Борисович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 101, "full_name": "Зотов Юрий Евгеньевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 75, "full_name": "Абрамов Роман Кириллович", "rank_name": "сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 76, "full_name": "Зотов Александр Александрович", "rank_name": "сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 53, "full_name": "Цветков Олег Юрьевич", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 51, "full_name": "Зотов Борис Романович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 60, "full_name": "Абрамов Николай Дмитриевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 64, "full_name": "Бобров Павел Павлович", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 54, "full_name": "Бобров Фёдор Николаевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 16, "full_name": "Рыбаков Александр Дмитриевич", "rank_name": "младший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-03", "totalAssigned": 12, "historicalImport": true}	2026-09-03	2026-09-04
356	2	1	2026-09-06 10:30:00+07	2026-09-07 10:30:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:53.9084+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 356, "note": null, "status": "approved", "ends_at": "2026-09-07T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-06T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 105, "full_name": "Абрамов Борис Романович", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 106, "full_name": "Зотов Игорь Игоревич", "rank_name": "старший прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 83, "full_name": "Цветков Юрий Евгеньевич", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 82, "full_name": "Панкратов Павел Павлович", "rank_name": "старший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 63, "full_name": "Цветков Кирилл Борисович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 65, "full_name": "Абрамов Юрий Евгеньевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 46, "full_name": "Зотов Павел Павлович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 48, "full_name": "Цветков Дмитрий Фёдорович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 7, "full_name": "Жданов Кирилл Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 356, "note": null, "status": "approved", "ends_at": "2026-09-07T10:30:00+07:00", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-06T10:30:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 2}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ"}, "broken": null, "weapons": [], "employee": {"id": 105, "full_name": "Абрамов Борис Романович", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ"}, "broken": null, "weapons": [], "employee": {"id": 106, "full_name": "Зотов Игорь Игоревич", "rank_name": "старший прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 83, "full_name": "Цветков Юрий Евгеньевич", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 82, "full_name": "Панкратов Павел Павлович", "rank_name": "старший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 63, "full_name": "Цветков Кирилл Борисович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 65, "full_name": "Абрамов Юрий Евгеньевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 46, "full_name": "Зотов Павел Павлович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null}, "broken": null, "weapons": [], "employee": {"id": 48, "full_name": "Цветков Дмитрий Фёдорович", "rank_name": "рядовой", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП"}, "broken": null, "weapons": [], "employee": {"id": 7, "full_name": "Жданов Кирилл Кириллович", "rank_name": "старшина", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП"}, "broken": null, "weapons": [], "employee": {"id": 38, "full_name": "Лукин Иван Викторович", "rank_name": "ефрейтор", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП"}, "broken": null, "weapons": [], "employee": {"id": 18, "full_name": "Тарасов Виктор Иванович", "rank_name": "старший сержант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП"}, "broken": null, "weapons": [], "employee": {"id": 41, "full_name": "Зотов Евгений Олегович", "rank_name": "рядовой", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-04", "totalAssigned": 12, "historicalImport": true}	2026-09-04	2026-09-06
381	3	1	2026-09-01 10:00:00+07	2026-09-02 10:00:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:54.056603+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 381, "note": null, "status": "approved", "ends_at": "2026-09-02T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-01T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 112, "full_name": "Панкратов Александр Александрович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 113, "full_name": "Цветков Евгений Олегович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 96, "full_name": "Зотов Николай Дмитриевич", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 39, "full_name": "Медведев Кирилл Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 57, "full_name": "Панкратов Роман Кириллович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 381, "note": null, "status": "approved", "ends_at": "2026-09-02T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-01T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 112, "full_name": "Панкратов Александр Александрович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 113, "full_name": "Цветков Евгений Олегович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 96, "full_name": "Зотов Николай Дмитриевич", "rank_name": "прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 39, "full_name": "Медведев Кирилл Григорьевич", "rank_name": "младший сержант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 57, "full_name": "Панкратов Роман Кириллович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-08-31", "totalAssigned": 5, "historicalImport": true}	2026-08-31	2026-09-01
382	3	1	2026-09-02 10:00:00+07	2026-09-03 10:00:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:54.061865+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 382, "note": null, "status": "approved", "ends_at": "2026-09-03T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-02T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 114, "full_name": "Бобров Николай Дмитриевич", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 115, "full_name": "Абрамов Тимур Тимурович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 99, "full_name": "Бобров Кирилл Борисович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 60, "full_name": "Абрамов Николай Дмитриевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 61, "full_name": "Зотов Тимур Тимурович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 382, "note": null, "status": "approved", "ends_at": "2026-09-03T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-02T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 114, "full_name": "Бобров Николай Дмитриевич", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 115, "full_name": "Абрамов Тимур Тимурович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 99, "full_name": "Бобров Кирилл Борисович", "rank_name": "прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 60, "full_name": "Абрамов Николай Дмитриевич", "rank_name": "ефрейтор", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 61, "full_name": "Зотов Тимур Тимурович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-01", "totalAssigned": 5, "historicalImport": true}	2026-09-01	2026-09-02
383	3	1	2026-09-03 10:00:00+07	2026-09-04 10:00:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:54.067084+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 383, "note": null, "status": "approved", "ends_at": "2026-09-04T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-03T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 117, "full_name": "Панкратов Кирилл Борисович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 118, "full_name": "Цветков Павел Павлович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 102, "full_name": "Панкратов Дмитрий Фёдорович", "rank_name": "старший прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 63, "full_name": "Цветков Кирилл Борисович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 65, "full_name": "Абрамов Юрий Евгеньевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 383, "note": null, "status": "approved", "ends_at": "2026-09-04T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-03T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 117, "full_name": "Панкратов Кирилл Борисович", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 118, "full_name": "Цветков Павел Павлович", "rank_name": "младший лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 102, "full_name": "Панкратов Дмитрий Фёдорович", "rank_name": "старший прапорщик", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 63, "full_name": "Цветков Кирилл Борисович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 65, "full_name": "Абрамов Юрий Евгеньевич", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-02", "totalAssigned": 5, "historicalImport": true}	2026-09-02	2026-09-03
1549	5	1	2026-10-30 10:00:00+07	2026-10-31 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:25.065173+07	2026-09-20 19:05:25.065173+07	\N	\N	\N	\N	\N	2026-10-30
1550	5	1	2026-10-31 10:00:00+07	2026-11-01 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:25.143985+07	2026-09-20 19:05:25.143985+07	\N	\N	\N	\N	\N	2026-10-31
1551	5	1	2026-11-01 10:00:00+07	2026-11-02 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:25.143985+07	2026-09-20 19:05:25.143985+07	\N	\N	\N	\N	\N	2026-11-01
1552	5	1	2026-11-02 10:00:00+07	2026-11-03 10:00:00+07	draft	1	\N	\N	\N	2026-09-20 19:05:25.143985+07	2026-09-20 19:05:25.143985+07	\N	\N	\N	\N	\N	2026-11-02
384	3	1	2026-09-04 10:00:00+07	2026-09-05 10:00:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:54.072552+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 384, "note": null, "status": "approved", "ends_at": "2026-09-05T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-04T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 119, "full_name": "Бобров Юрий Евгеньевич", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 121, "full_name": "Зотов Максим Максимович", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 105, "full_name": "Абрамов Борис Романович", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 67, "full_name": "Панкратов Максим Максимович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 69, "full_name": "Бобров Борис Романович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 384, "note": null, "status": "approved", "ends_at": "2026-09-05T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-04T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 119, "full_name": "Бобров Юрий Евгеньевич", "rank_name": "младший лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 121, "full_name": "Зотов Максим Максимович", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 105, "full_name": "Абрамов Борис Романович", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 67, "full_name": "Панкратов Максим Максимович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 69, "full_name": "Бобров Борис Романович", "rank_name": "ефрейтор", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-03", "totalAssigned": 5, "historicalImport": true}	2026-09-03	2026-09-04
385	3	1	2026-09-05 10:00:00+07	2026-09-06 10:00:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:54.078386+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 385, "note": null, "status": "approved", "ends_at": "2026-09-06T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-05T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 123, "full_name": "Цветков Борис Романович", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 124, "full_name": "Бобров Игорь Игоревич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 107, "full_name": "Панкратов Олег Юрьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 81, "full_name": "Зотов Кирилл Борисович", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 84, "full_name": "Бобров Дмитрий Фёдорович", "rank_name": "старший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 385, "note": null, "status": "approved", "ends_at": "2026-09-06T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-05T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 123, "full_name": "Цветков Борис Романович", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 124, "full_name": "Бобров Игорь Игоревич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 107, "full_name": "Панкратов Олег Юрьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 81, "full_name": "Зотов Кирилл Борисович", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 84, "full_name": "Бобров Дмитрий Фёдорович", "rank_name": "старший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}, {"duty": {"id": 386, "note": null, "status": "approved", "ends_at": "2026-09-07T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-06T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 125, "full_name": "Абрамов Олег Юрьевич", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 126, "full_name": "Зотов Фёдор Николаевич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 109, "full_name": "Бобров Геннадий Геннадьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 87, "full_name": "Панкратов Борис Романович", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 89, "full_name": "Бобров Олег Юрьевич", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-04", "totalAssigned": 10, "historicalImport": true}	2026-09-04	2026-09-05
386	3	1	2026-09-06 10:00:00+07	2026-09-07 10:00:00+07	approved	\N	\N	2026-09-07 14:48:10.30052+07	\N	2026-09-07 14:47:54.083836+07	2026-09-11 23:31:51.793175+07	\N	\N	{"duty": {"id": 386, "note": null, "status": "approved", "ends_at": "2026-09-07T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-06T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 125, "full_name": "Абрамов Олег Юрьевич", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 126, "full_name": "Зотов Фёдор Николаевич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 109, "full_name": "Бобров Геннадий Геннадьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 87, "full_name": "Панкратов Борис Романович", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 89, "full_name": "Бобров Олег Юрьевич", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 385, "note": null, "status": "approved", "ends_at": "2026-09-06T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-05T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 123, "full_name": "Цветков Борис Романович", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 124, "full_name": "Бобров Игорь Игоревич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 107, "full_name": "Панкратов Олег Юрьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 81, "full_name": "Зотов Кирилл Борисович", "rank_name": "старший сержант", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 84, "full_name": "Бобров Дмитрий Фёдорович", "rank_name": "старший сержант", "unit_short": "2 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}, {"duty": {"id": 386, "note": null, "status": "approved", "ends_at": "2026-09-07T10:00:00+07:00", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-06T10:00:00+07:00", "unit_name": "Войсковая часть 00000 (условная)", "unit_short": "в/ч 00000", "duty_type_id": 3}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД"}, "broken": null, "weapons": [], "employee": {"id": 125, "full_name": "Абрамов Олег Юрьевич", "rank_name": "лейтенант", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД"}, "broken": null, "weapons": [], "employee": {"id": 126, "full_name": "Зотов Фёдор Николаевич", "rank_name": "лейтенант", "unit_short": "УС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД"}, "broken": null, "weapons": [], "employee": {"id": 109, "full_name": "Бобров Геннадий Геннадьевич", "rank_name": "старший прапорщик", "unit_short": "ТС"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО"}, "broken": null, "weapons": [], "employee": {"id": 87, "full_name": "Панкратов Борис Романович", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О"}, "broken": null, "weapons": [], "employee": {"id": 89, "full_name": "Бобров Олег Юрьевич", "rank_name": "старшина", "unit_short": "1 рота"}, "isOverride": false, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "unitName": "Войсковая часть 00000 (условная)", "orderDate": "2026-09-04", "totalAssigned": 10, "historicalImport": true}	2026-09-04	2026-09-06
418	1	1	2026-10-06 17:30:00+07	2026-10-09 17:30:00+07	draft	\N	\N	\N	\N	2026-09-13 11:09:46.136708+07	2026-09-13 11:09:46.136708+07	\N	\N	\N	\N	\N	2026-10-06
1553	1	1	2026-10-30 17:30:00+07	2026-11-03 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:16.66724+07	2026-09-20 19:35:16.66724+07	\N	\N	\N	\N	\N	2026-10-30
1554	1	1	2026-11-03 17:30:00+07	2026-11-06 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:16.92442+07	2026-09-20 19:35:16.92442+07	\N	\N	\N	\N	\N	2026-11-03
1555	1	1	2026-11-06 17:30:00+07	2026-11-10 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:17.146491+07	2026-09-20 19:35:17.146491+07	\N	\N	\N	\N	\N	2026-11-06
1556	1	1	2026-11-10 17:30:00+07	2026-11-13 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:17.409752+07	2026-09-20 19:35:17.409752+07	\N	\N	\N	\N	\N	2026-11-10
1557	1	1	2026-11-13 17:30:00+07	2026-11-17 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:17.624779+07	2026-09-20 19:35:17.624779+07	\N	\N	\N	\N	\N	2026-11-13
1558	1	1	2026-11-17 17:30:00+07	2026-11-20 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:17.885166+07	2026-09-20 19:35:17.885166+07	\N	\N	\N	\N	\N	2026-11-17
1559	1	1	2026-11-20 17:30:00+07	2026-11-24 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:18.10492+07	2026-09-20 19:35:18.10492+07	\N	\N	\N	\N	\N	2026-11-20
1560	1	1	2026-11-24 17:30:00+07	2026-11-27 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:18.366559+07	2026-09-20 19:35:18.366559+07	\N	\N	\N	\N	\N	2026-11-24
1561	1	1	2026-11-27 17:30:00+07	2026-12-01 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:35:18.599014+07	2026-09-20 19:35:18.599014+07	\N	\N	\N	\N	\N	2026-11-27
1563	1	1	2026-10-09 17:30:00+07	2026-10-13 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:19.609032+07	2026-09-20 19:39:19.609032+07	\N	\N	\N	\N	\N	2026-10-09
1564	1	1	2026-10-13 17:30:00+07	2026-10-16 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:19.854092+07	2026-09-20 19:39:19.854092+07	\N	\N	\N	\N	\N	2026-10-13
1565	1	1	2026-10-16 17:30:00+07	2026-10-20 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:20.054591+07	2026-09-20 19:39:20.054591+07	\N	\N	\N	\N	\N	2026-10-16
1018	2	1	2027-01-13 10:30:00+07	2027-01-14 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:03.865095+07	2026-09-19 14:57:03.865095+07	\N	\N	\N	\N	\N	2027-01-13
1020	2	1	2027-01-15 10:30:00+07	2027-01-16 10:30:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:04.136352+07	2026-09-19 14:57:04.136352+07	\N	\N	\N	\N	\N	2027-01-15
1049	3	1	2027-01-12 10:00:00+07	2027-01-13 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:08.801624+07	2026-09-19 14:57:08.801624+07	\N	\N	\N	\N	\N	2027-01-12
1056	3	1	2027-01-19 10:00:00+07	2027-01-20 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:09.401198+07	2026-09-19 14:57:09.401198+07	\N	\N	\N	\N	\N	2027-01-19
1064	3	1	2027-01-27 10:00:00+07	2027-01-28 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 14:57:10.10137+07	2026-09-19 14:57:10.10137+07	\N	\N	\N	\N	\N	2027-01-27
1141	2	1	2026-11-14 10:30:00+07	2026-11-15 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.973159+07	2026-09-19 15:01:45.973159+07	\N	\N	\N	\N	\N	2026-11-14
1142	2	1	2026-11-15 10:30:00+07	2026-11-16 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.982126+07	2026-09-19 15:01:45.982126+07	\N	\N	\N	\N	\N	2026-11-15
1143	2	1	2026-11-16 10:30:00+07	2026-11-17 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:45.983314+07	2026-09-19 15:01:45.983314+07	\N	\N	\N	\N	\N	2026-11-16
1160	2	1	2027-02-03 10:30:00+07	2027-02-04 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:48.60933+07	2026-09-19 15:01:48.60933+07	\N	\N	\N	\N	\N	2027-02-03
1162	2	1	2027-02-05 10:30:00+07	2027-02-06 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:48.899268+07	2026-09-19 15:01:48.899268+07	\N	\N	\N	\N	\N	2027-02-05
1166	2	1	2027-02-09 10:30:00+07	2027-02-10 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:49.636088+07	2026-09-19 15:01:49.636088+07	\N	\N	\N	\N	\N	2027-02-09
1168	2	1	2027-02-11 10:30:00+07	2027-02-12 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:49.935663+07	2026-09-19 15:01:49.935663+07	\N	\N	\N	\N	\N	2027-02-11
1173	2	1	2027-02-16 10:30:00+07	2027-02-17 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:50.828397+07	2026-09-19 15:01:50.828397+07	\N	\N	\N	\N	\N	2027-02-16
1182	2	1	2027-02-25 10:30:00+07	2027-02-26 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:01:52.382595+07	2026-09-19 15:01:52.382595+07	\N	\N	\N	\N	\N	2027-02-25
1471	2	1	2026-12-23 10:30:00+07	2026-12-24 10:30:00+07	draft	\N	\N	\N	\N	2026-09-19 15:20:10.625685+07	2026-09-19 15:20:10.625685+07	\N	\N	\N	\N	\N	2026-12-23
1477	3	1	2026-10-01 10:00:00+07	2026-10-02 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:50.627993+07	2026-09-19 16:45:50.627993+07	\N	\N	\N	\N	\N	2026-10-01
1479	3	1	2026-10-03 10:00:00+07	2026-10-04 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:50.820263+07	2026-09-19 16:45:50.820263+07	\N	\N	\N	\N	\N	2026-10-03
1480	3	1	2026-10-04 10:00:00+07	2026-10-05 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:50.828304+07	2026-09-19 16:45:50.828304+07	\N	\N	\N	\N	\N	2026-10-04
1481	3	1	2026-10-05 10:00:00+07	2026-10-06 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:50.829663+07	2026-09-19 16:45:50.829663+07	\N	\N	\N	\N	\N	2026-10-05
1485	3	1	2026-10-09 10:00:00+07	2026-10-10 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.269714+07	2026-09-19 16:45:51.269714+07	\N	\N	\N	\N	\N	2026-10-09
1489	3	1	2026-10-13 10:00:00+07	2026-10-14 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.579189+07	2026-09-19 16:45:51.579189+07	\N	\N	\N	\N	\N	2026-10-13
1490	3	1	2026-10-14 10:00:00+07	2026-10-15 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.654111+07	2026-09-19 16:45:51.654111+07	\N	\N	\N	\N	\N	2026-10-14
1492	3	1	2026-10-16 10:00:00+07	2026-10-17 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:51.796506+07	2026-09-19 16:45:51.796506+07	\N	\N	\N	\N	\N	2026-10-16
1497	3	1	2026-10-21 10:00:00+07	2026-10-22 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.191049+07	2026-09-19 16:45:52.191049+07	\N	\N	\N	\N	\N	2026-10-21
1504	3	1	2026-10-28 10:00:00+07	2026-10-29 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.725731+07	2026-09-19 16:45:52.725731+07	\N	\N	\N	\N	\N	2026-10-28
1505	3	1	2026-10-29 10:00:00+07	2026-10-30 10:00:00+07	draft	1	\N	\N	\N	2026-09-19 16:45:52.798983+07	2026-09-19 16:45:52.798983+07	\N	\N	\N	\N	\N	2026-10-29
1566	1	1	2026-10-20 17:30:00+07	2026-10-23 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:20.299202+07	2026-09-20 19:39:20.299202+07	\N	\N	\N	\N	\N	2026-10-20
1567	1	1	2026-10-23 17:30:00+07	2026-10-27 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:20.498088+07	2026-09-20 19:39:20.498088+07	\N	\N	\N	\N	\N	2026-10-23
1568	1	1	2026-10-27 17:30:00+07	2026-10-30 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:20.738254+07	2026-09-20 19:39:20.738254+07	\N	\N	\N	\N	\N	2026-10-27
1569	1	1	2026-12-01 17:30:00+07	2026-12-04 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:21.143319+07	2026-09-20 19:39:21.143319+07	\N	\N	\N	\N	\N	2026-12-01
1570	1	1	2026-12-04 17:30:00+07	2026-12-08 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:21.407265+07	2026-09-20 19:39:21.407265+07	\N	\N	\N	\N	\N	2026-12-04
1571	1	1	2026-12-08 17:30:00+07	2026-12-11 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:21.726515+07	2026-09-20 19:39:21.726515+07	\N	\N	\N	\N	\N	2026-12-08
1572	1	1	2026-12-11 17:30:00+07	2026-12-15 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:22.000365+07	2026-09-20 19:39:22.000365+07	\N	\N	\N	\N	\N	2026-12-11
1573	1	1	2026-12-15 17:30:00+07	2026-12-18 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:22.333096+07	2026-09-20 19:39:22.333096+07	\N	\N	\N	\N	\N	2026-12-15
1574	1	1	2026-12-18 17:30:00+07	2026-12-22 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:22.617453+07	2026-09-20 19:39:22.617453+07	\N	\N	\N	\N	\N	2026-12-18
1575	1	1	2026-12-22 17:30:00+07	2026-12-25 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:22.961951+07	2026-09-20 19:39:22.961951+07	\N	\N	\N	\N	\N	2026-12-22
1576	1	1	2026-12-25 17:30:00+07	2026-12-29 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:23.257244+07	2026-09-20 19:39:23.257244+07	\N	\N	\N	\N	\N	2026-12-25
1577	1	1	2026-12-29 17:30:00+07	2027-01-01 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:23.61405+07	2026-09-20 19:39:23.61405+07	\N	\N	\N	\N	\N	2026-12-29
1578	1	1	2027-01-01 17:30:00+07	2027-01-05 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:23.984965+07	2026-09-20 19:39:23.984965+07	\N	\N	\N	\N	\N	2027-01-01
1579	1	1	2027-01-05 17:30:00+07	2027-01-08 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:23.984965+07	2026-09-20 19:39:23.984965+07	\N	\N	\N	\N	\N	2027-01-05
1580	1	1	2027-01-08 17:30:00+07	2027-01-12 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:23.984965+07	2026-09-20 19:39:23.984965+07	\N	\N	\N	\N	\N	2027-01-08
1581	1	1	2027-01-12 17:30:00+07	2027-01-15 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:24.924205+07	2026-09-20 19:39:24.924205+07	\N	\N	\N	\N	\N	2027-01-12
1582	1	1	2027-01-15 17:30:00+07	2027-01-19 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:25.241955+07	2026-09-20 19:39:25.241955+07	\N	\N	\N	\N	\N	2027-01-15
1583	1	1	2027-01-19 17:30:00+07	2027-01-22 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:25.635389+07	2026-09-20 19:39:25.635389+07	\N	\N	\N	\N	\N	2027-01-19
1584	1	1	2027-01-22 17:30:00+07	2027-01-26 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:25.968981+07	2026-09-20 19:39:25.968981+07	\N	\N	\N	\N	\N	2027-01-22
1585	1	1	2027-01-26 17:30:00+07	2027-01-29 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:26.373959+07	2026-09-20 19:39:26.373959+07	\N	\N	\N	\N	\N	2027-01-26
1586	1	1	2027-01-29 17:30:00+07	2027-02-02 17:30:00+07	draft	\N	\N	\N	\N	2026-09-20 19:39:26.711484+07	2026-09-20 19:39:26.711484+07	\N	\N	\N	\N	\N	2027-01-29
348	1	1	2026-09-22 17:30:00+07	2026-09-25 17:30:00+07	approved	\N	1	2026-09-20 19:40:24.92007+07	\N	2026-09-07 14:47:53.79248+07	2026-09-20 19:40:24.92007+07	\N	\N	{"duty": {"id": 348, "note": null, "status": "approved", "ends_at": "2026-09-25T10:30:00.000Z", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-22T10:30:00.000Z", "unit_name": "В/Ч", "unit_short": "в/ч 00011", "duty_type_id": 1, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 123, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 125, "is_active": true, "serial_number": "TEST-125", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 125, "rank_id": 10, "unit_id": 5, "position": "командир взвода", "full_name": "Абрамов Олег Юрьевич", "last_name": "Абрамов", "rank_name": "лейтенант", "seniority": 100, "first_name": "Олег", "rank_short": "л-т", "short_name": "л-т Абрамов О.Ю.", "unit_short": "ТС", "middle_name": "Юрьевич", "personnel_number": "С-01085"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 124, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 126, "is_active": true, "serial_number": "TEST-126", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 126, "rank_id": 10, "unit_id": 4, "position": "командир взвода", "full_name": "Зотов Фёдор Николаевич", "last_name": "Зотов", "rank_name": "лейтенант", "seniority": 100, "first_name": "Фёдор", "rank_short": "л-т", "short_name": "л-т Зотов Ф.Н.", "unit_short": "УС", "middle_name": "Николаевич", "personnel_number": "С-01086"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 95, "kind": "rifle", "name": "Учебный автомат", "owner_id": 97, "is_active": true, "serial_number": "TEST-97", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 97, "rank_id": 7, "unit_id": 5, "position": "техник", "full_name": "Панкратов Тимур Тимурович", "last_name": "Панкратов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Тимур", "rank_short": "пр-к", "short_name": "пр-к Панкратов Т.Т.", "unit_short": "ТС", "middle_name": "Тимурович", "personnel_number": "С-01057"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 12, "kind": "rifle", "name": "Учебный автомат", "owner_id": 14, "is_active": true, "serial_number": "TEST-14", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 14, "rank_id": 2, "unit_id": 4, "position": "командир отделения", "full_name": "Орлов Сергей Викторович", "last_name": "Орлов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Сергей", "rank_short": "ефр.", "short_name": "ефр. Орлов С.В.", "unit_short": "УС", "middle_name": "Викторович", "personnel_number": "Т-0014"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 27, "kind": "rifle", "name": "Учебный автомат", "owner_id": 29, "is_active": true, "serial_number": "TEST-29", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 29, "rank_id": 4, "unit_id": 19, "position": "старший техник", "full_name": "Баранов Роман Евгеньевич", "last_name": "Баранов", "rank_name": "сержант", "seniority": 40, "first_name": "Роман", "rank_short": "с-т", "short_name": "с-т Баранов Р.Е.", "unit_short": "2 отделение", "middle_name": "Евгеньевич", "personnel_number": "Т-0029"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 34, "kind": "rifle", "name": "Учебный автомат", "owner_id": 36, "is_active": true, "serial_number": "TEST-36", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 36, "rank_id": 1, "unit_id": 26, "position": "оператор", "full_name": "Исаев Дмитрий Александрович", "last_name": "Исаев", "rank_name": "рядовой", "seniority": 10, "first_name": "Дмитрий", "rank_short": "р-й", "short_name": "р-й Исаев Д.А.", "unit_short": "3 отделение", "middle_name": "Александрович", "personnel_number": "Т-0036"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 26, "kind": "rifle", "name": "Учебный автомат", "owner_id": 28, "is_active": true, "serial_number": "TEST-28", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 28, "rank_id": 3, "unit_id": 22, "position": "оператор", "full_name": "Антонов Павел Дмитриевич", "last_name": "Антонов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Павел", "rank_short": "мл. с-т", "short_name": "мл. с-т Антонов П.Д.", "unit_short": "2 отделение", "middle_name": "Дмитриевич", "personnel_number": "Т-0028"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 4, "kind": "rifle", "name": "Учебный автомат", "owner_id": 5, "is_active": true, "serial_number": "TEST-5", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 5, "rank_id": 4, "unit_id": 17, "position": "старший техник", "full_name": "Данилов Евгений Евгеньевич", "last_name": "Данилов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Данилов Е.Е.", "unit_short": "3 отделение", "middle_name": "Евгеньевич", "personnel_number": "Т-0005"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 27, "name": "Пост технических средств охраны 1", "short_name": "ПТСО 1", "start_time": "08:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-23", "weapons": [{"id": 79, "kind": "rifle", "name": "Учебный автомат", "owner_id": 81, "is_active": true, "serial_number": "TEST-81", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 81, "rank_id": 5, "unit_id": 23, "position": "командир отделения", "full_name": "Зотов Кирилл Борисович", "last_name": "Зотов", "rank_name": "старший сержант", "seniority": 50, "first_name": "Кирилл", "rank_short": "ст. с-т", "short_name": "ст. с-т Зотов К.Б.", "unit_short": "3 отделение", "middle_name": "Борисович", "personnel_number": "С-01041"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 27, "name": "Пост технических средств охраны 1", "short_name": "ПТСО 1", "start_time": "08:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-24", "weapons": [{"id": 75, "kind": "rifle", "name": "Учебный автомат", "owner_id": 77, "is_active": true, "serial_number": "TEST-77", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 77, "rank_id": 4, "unit_id": 28, "position": "командир отделения", "full_name": "Панкратов Евгений Олегович", "last_name": "Панкратов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Панкратов Е.О.", "unit_short": "2 отделение", "middle_name": "Олегович", "personnel_number": "С-01037"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 27, "name": "Пост технических средств охраны 1", "short_name": "ПТСО 1", "start_time": "08:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-25", "weapons": [{"id": 86, "kind": "rifle", "name": "Учебный автомат", "owner_id": 88, "is_active": true, "serial_number": "TEST-88", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 88, "rank_id": 6, "unit_id": 8, "position": "командир отделения", "full_name": "Цветков Игорь Игоревич", "last_name": "Цветков", "rank_name": "старшина", "seniority": 60, "first_name": "Игорь", "rank_short": "ст-на", "short_name": "ст-на Цветков И.И.", "unit_short": "3 взвод", "middle_name": "Игоревич", "personnel_number": "С-01048"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 28, "name": "Пост технических средств охраны 2", "short_name": "ПТСО 2", "start_time": "20:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-22", "weapons": [{"id": 73, "kind": "rifle", "name": "Учебный автомат", "owner_id": 75, "is_active": true, "serial_number": "TEST-75", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 75, "rank_id": 4, "unit_id": 27, "position": "командир отделения", "full_name": "Абрамов Роман Кириллович", "last_name": "Абрамов", "rank_name": "сержант", "seniority": 40, "first_name": "Роман", "rank_short": "с-т", "short_name": "с-т Абрамов Р.К.", "unit_short": "1 отделение", "middle_name": "Кириллович", "personnel_number": "С-01035"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 28, "name": "Пост технических средств охраны 2", "short_name": "ПТСО 2", "start_time": "20:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-23", "weapons": [{"id": 100, "kind": "rifle", "name": "Учебный автомат", "owner_id": 102, "is_active": true, "serial_number": "TEST-102", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 102, "rank_id": 8, "unit_id": 4, "position": "техник", "full_name": "Панкратов Дмитрий Фёдорович", "last_name": "Панкратов", "rank_name": "старший прапорщик", "seniority": 80, "first_name": "Дмитрий", "rank_short": "ст. пр-к", "short_name": "ст. пр-к Панкратов Д.Ф.", "unit_short": "УС", "middle_name": "Фёдорович", "personnel_number": "С-01062"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 28, "name": "Пост технических средств охраны 2", "short_name": "ПТСО 2", "start_time": "20:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-24", "weapons": [{"id": 94, "kind": "rifle", "name": "Учебный автомат", "owner_id": 96, "is_active": true, "serial_number": "TEST-96", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 96, "rank_id": 7, "unit_id": 4, "position": "техник", "full_name": "Зотов Николай Дмитриевич", "last_name": "Зотов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Николай", "rank_short": "пр-к", "short_name": "пр-к Зотов Н.Д.", "unit_short": "УС", "middle_name": "Дмитриевич", "personnel_number": "С-01056"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 29, "name": "Пост управления доступом 1", "short_name": "ПУД 1", "start_time": "08:00:00", "duration_hours": 10}, "broken": null, "onDate": null, "weapons": [{"id": 37, "kind": "rifle", "name": "Учебный автомат", "owner_id": 39, "is_active": true, "serial_number": "TEST-39", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 39, "rank_id": 3, "unit_id": 5, "position": "заместитель командира взвода", "full_name": "Медведев Кирилл Григорьевич", "last_name": "Медведев", "rank_name": "младший сержант", "seniority": 30, "first_name": "Кирилл", "rank_short": "мл. с-т", "short_name": "мл. с-т Медведев К.Г.", "unit_short": "ТС", "middle_name": "Григорьевич", "personnel_number": "Т-0039"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 30, "name": "Пост управления доступом 2", "short_name": "ПУД 2", "start_time": "08:00:00", "duration_hours": 10}, "broken": null, "onDate": null, "weapons": [{"id": 93, "kind": "rifle", "name": "Учебный автомат", "owner_id": 95, "is_active": true, "serial_number": "TEST-95", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 95, "rank_id": 7, "unit_id": 5, "position": "техник", "full_name": "Абрамов Евгений Олегович", "last_name": "Абрамов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Евгений", "rank_short": "пр-к", "short_name": "пр-к Абрамов Е.О.", "unit_short": "ТС", "middle_name": "Олегович", "personnel_number": "С-01055"}, "isOverride": false, "overrideReason": null}], "postCount": 16, "brokenCount": 0}	{"dutyType": {"code": "OO", "name": "Дежурная смена «Охрана и оборона»"}, "sections": [{"duty": {"id": 348, "note": null, "status": "approved", "ends_at": "2026-09-25T10:30:00.000Z", "unit_id": 1, "duty_code": "OO", "duty_name": "Дежурная смена «Охрана и оборона»", "starts_at": "2026-09-22T10:30:00.000Z", "unit_name": "В/Ч", "unit_short": "в/ч 00011", "duty_type_id": 1, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 18, "name": "Командир дежурной смены", "short_name": "КДС", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 123, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 125, "is_active": true, "serial_number": "TEST-125", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 125, "rank_id": 10, "unit_id": 5, "position": "командир взвода", "full_name": "Абрамов Олег Юрьевич", "last_name": "Абрамов", "rank_name": "лейтенант", "seniority": 100, "first_name": "Олег", "rank_short": "л-т", "short_name": "л-т Абрамов О.Ю.", "unit_short": "ТС", "middle_name": "Юрьевич", "personnel_number": "С-01085"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 19, "name": "Заместитель командира дежурной смены", "short_name": "ЗКДС", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 124, "kind": "pistol", "name": "Учебный пистолет", "owner_id": 126, "is_active": true, "serial_number": "TEST-126", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 126, "rank_id": 10, "unit_id": 4, "position": "командир взвода", "full_name": "Зотов Фёдор Николаевич", "last_name": "Зотов", "rank_name": "лейтенант", "seniority": 100, "first_name": "Фёдор", "rank_short": "л-т", "short_name": "л-т Зотов Ф.Н.", "unit_short": "УС", "middle_name": "Николаевич", "personnel_number": "С-01086"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 20, "name": "Начальник ПНР", "short_name": "НПНР", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 95, "kind": "rifle", "name": "Учебный автомат", "owner_id": 97, "is_active": true, "serial_number": "TEST-97", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 97, "rank_id": 7, "unit_id": 5, "position": "техник", "full_name": "Панкратов Тимур Тимурович", "last_name": "Панкратов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Тимур", "rank_short": "пр-к", "short_name": "пр-к Панкратов Т.Т.", "unit_short": "ТС", "middle_name": "Тимурович", "personnel_number": "С-01057"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 21, "name": "Номер расчета 1", "short_name": "1", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 12, "kind": "rifle", "name": "Учебный автомат", "owner_id": 14, "is_active": true, "serial_number": "TEST-14", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 14, "rank_id": 2, "unit_id": 4, "position": "командир отделения", "full_name": "Орлов Сергей Викторович", "last_name": "Орлов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Сергей", "rank_short": "ефр.", "short_name": "ефр. Орлов С.В.", "unit_short": "УС", "middle_name": "Викторович", "personnel_number": "Т-0014"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 22, "name": "Номер расчета 2", "short_name": "2", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 27, "kind": "rifle", "name": "Учебный автомат", "owner_id": 29, "is_active": true, "serial_number": "TEST-29", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 29, "rank_id": 4, "unit_id": 19, "position": "старший техник", "full_name": "Баранов Роман Евгеньевич", "last_name": "Баранов", "rank_name": "сержант", "seniority": 40, "first_name": "Роман", "rank_short": "с-т", "short_name": "с-т Баранов Р.Е.", "unit_short": "2 отделение", "middle_name": "Евгеньевич", "personnel_number": "Т-0029"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 23, "name": "Номер расчета 3", "short_name": "3", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 34, "kind": "rifle", "name": "Учебный автомат", "owner_id": 36, "is_active": true, "serial_number": "TEST-36", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 36, "rank_id": 1, "unit_id": 26, "position": "оператор", "full_name": "Исаев Дмитрий Александрович", "last_name": "Исаев", "rank_name": "рядовой", "seniority": 10, "first_name": "Дмитрий", "rank_short": "р-й", "short_name": "р-й Исаев Д.А.", "unit_short": "3 отделение", "middle_name": "Александрович", "personnel_number": "Т-0036"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 24, "name": "Номер расчета 4", "short_name": "4", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 26, "kind": "rifle", "name": "Учебный автомат", "owner_id": 28, "is_active": true, "serial_number": "TEST-28", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 28, "rank_id": 3, "unit_id": 22, "position": "оператор", "full_name": "Антонов Павел Дмитриевич", "last_name": "Антонов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Павел", "rank_short": "мл. с-т", "short_name": "мл. с-т Антонов П.Д.", "unit_short": "2 отделение", "middle_name": "Дмитриевич", "personnel_number": "Т-0028"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 25, "name": "Номер расчета 5", "short_name": "5", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapons": [{"id": 4, "kind": "rifle", "name": "Учебный автомат", "owner_id": 5, "is_active": true, "serial_number": "TEST-5", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 5, "rank_id": 4, "unit_id": 17, "position": "старший техник", "full_name": "Данилов Евгений Евгеньевич", "last_name": "Данилов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Данилов Е.Е.", "unit_short": "3 отделение", "middle_name": "Евгеньевич", "personnel_number": "Т-0005"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 27, "name": "Пост технических средств охраны 1", "short_name": "ПТСО 1", "start_time": "08:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-23", "weapons": [{"id": 79, "kind": "rifle", "name": "Учебный автомат", "owner_id": 81, "is_active": true, "serial_number": "TEST-81", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 81, "rank_id": 5, "unit_id": 23, "position": "командир отделения", "full_name": "Зотов Кирилл Борисович", "last_name": "Зотов", "rank_name": "старший сержант", "seniority": 50, "first_name": "Кирилл", "rank_short": "ст. с-т", "short_name": "ст. с-т Зотов К.Б.", "unit_short": "3 отделение", "middle_name": "Борисович", "personnel_number": "С-01041"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 27, "name": "Пост технических средств охраны 1", "short_name": "ПТСО 1", "start_time": "08:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-24", "weapons": [{"id": 75, "kind": "rifle", "name": "Учебный автомат", "owner_id": 77, "is_active": true, "serial_number": "TEST-77", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 77, "rank_id": 4, "unit_id": 28, "position": "командир отделения", "full_name": "Панкратов Евгений Олегович", "last_name": "Панкратов", "rank_name": "сержант", "seniority": 40, "first_name": "Евгений", "rank_short": "с-т", "short_name": "с-т Панкратов Е.О.", "unit_short": "2 отделение", "middle_name": "Олегович", "personnel_number": "С-01037"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 27, "name": "Пост технических средств охраны 1", "short_name": "ПТСО 1", "start_time": "08:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-25", "weapons": [{"id": 86, "kind": "rifle", "name": "Учебный автомат", "owner_id": 88, "is_active": true, "serial_number": "TEST-88", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 88, "rank_id": 6, "unit_id": 8, "position": "командир отделения", "full_name": "Цветков Игорь Игоревич", "last_name": "Цветков", "rank_name": "старшина", "seniority": 60, "first_name": "Игорь", "rank_short": "ст-на", "short_name": "ст-на Цветков И.И.", "unit_short": "3 взвод", "middle_name": "Игоревич", "personnel_number": "С-01048"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 28, "name": "Пост технических средств охраны 2", "short_name": "ПТСО 2", "start_time": "20:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-22", "weapons": [{"id": 73, "kind": "rifle", "name": "Учебный автомат", "owner_id": 75, "is_active": true, "serial_number": "TEST-75", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 75, "rank_id": 4, "unit_id": 27, "position": "командир отделения", "full_name": "Абрамов Роман Кириллович", "last_name": "Абрамов", "rank_name": "сержант", "seniority": 40, "first_name": "Роман", "rank_short": "с-т", "short_name": "с-т Абрамов Р.К.", "unit_short": "1 отделение", "middle_name": "Кириллович", "personnel_number": "С-01035"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 28, "name": "Пост технических средств охраны 2", "short_name": "ПТСО 2", "start_time": "20:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-23", "weapons": [{"id": 100, "kind": "rifle", "name": "Учебный автомат", "owner_id": 102, "is_active": true, "serial_number": "TEST-102", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 102, "rank_id": 8, "unit_id": 4, "position": "техник", "full_name": "Панкратов Дмитрий Фёдорович", "last_name": "Панкратов", "rank_name": "старший прапорщик", "seniority": 80, "first_name": "Дмитрий", "rank_short": "ст. пр-к", "short_name": "ст. пр-к Панкратов Д.Ф.", "unit_short": "УС", "middle_name": "Фёдорович", "personnel_number": "С-01062"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 28, "name": "Пост технических средств охраны 2", "short_name": "ПТСО 2", "start_time": "20:00:00", "duration_hours": 12}, "broken": null, "onDate": "2026-09-24", "weapons": [{"id": 94, "kind": "rifle", "name": "Учебный автомат", "owner_id": 96, "is_active": true, "serial_number": "TEST-96", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 96, "rank_id": 7, "unit_id": 4, "position": "техник", "full_name": "Зотов Николай Дмитриевич", "last_name": "Зотов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Николай", "rank_short": "пр-к", "short_name": "пр-к Зотов Н.Д.", "unit_short": "УС", "middle_name": "Дмитриевич", "personnel_number": "С-01056"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 29, "name": "Пост управления доступом 1", "short_name": "ПУД 1", "start_time": "08:00:00", "duration_hours": 10}, "broken": null, "onDate": null, "weapons": [{"id": 37, "kind": "rifle", "name": "Учебный автомат", "owner_id": 39, "is_active": true, "serial_number": "TEST-39", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 39, "rank_id": 3, "unit_id": 5, "position": "заместитель командира взвода", "full_name": "Медведев Кирилл Григорьевич", "last_name": "Медведев", "rank_name": "младший сержант", "seniority": 30, "first_name": "Кирилл", "rank_short": "мл. с-т", "short_name": "мл. с-т Медведев К.Г.", "unit_short": "ТС", "middle_name": "Григорьевич", "personnel_number": "Т-0039"}, "isOverride": false, "overrideReason": null}, {"note": null, "post": {"id": 30, "name": "Пост управления доступом 2", "short_name": "ПУД 2", "start_time": "08:00:00", "duration_hours": 10}, "broken": null, "onDate": null, "weapons": [{"id": 93, "kind": "rifle", "name": "Учебный автомат", "owner_id": 95, "is_active": true, "serial_number": "TEST-95", "manufactured_on": "2023-12-31T17:00:00.000Z"}], "employee": {"id": 95, "rank_id": 7, "unit_id": 5, "position": "техник", "full_name": "Абрамов Евгений Олегович", "last_name": "Абрамов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Евгений", "rank_short": "пр-к", "short_name": "пр-к Абрамов Е.О.", "unit_short": "ТС", "middle_name": "Олегович", "personnel_number": "С-01055"}, "isOverride": false, "overrideReason": null}], "postCount": 16, "brokenCount": 0}], "unitName": "В/Ч", "orderDate": "2026-09-21", "totalAssigned": 16}	2026-09-21	2026-09-22
1587	2	1	2026-10-01 10:30:00+07	2026-10-02 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.400934+07	2026-09-26 16:41:07.400934+07	\N	\N	\N	\N	\N	2026-10-01
1588	2	1	2026-10-02 10:30:00+07	2026-10-03 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.531386+07	2026-09-26 16:41:07.531386+07	\N	\N	\N	\N	\N	2026-10-02
1589	2	1	2026-10-03 10:30:00+07	2026-10-04 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.646237+07	2026-09-26 16:41:07.646237+07	\N	\N	\N	\N	\N	2026-10-03
1590	2	1	2026-10-04 10:30:00+07	2026-10-05 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.646237+07	2026-09-26 16:41:07.646237+07	\N	\N	\N	\N	\N	2026-10-04
1591	2	1	2026-10-05 10:30:00+07	2026-10-06 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.646237+07	2026-09-26 16:41:07.646237+07	\N	\N	\N	\N	\N	2026-10-05
1592	2	1	2026-10-06 10:30:00+07	2026-10-07 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.851714+07	2026-09-26 16:41:07.851714+07	\N	\N	\N	\N	\N	2026-10-06
1593	2	1	2026-10-07 10:30:00+07	2026-10-08 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:07.958044+07	2026-09-26 16:41:07.958044+07	\N	\N	\N	\N	\N	2026-10-07
1594	2	1	2026-10-08 10:30:00+07	2026-10-09 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.073377+07	2026-09-26 16:41:08.073377+07	\N	\N	\N	\N	\N	2026-10-08
1595	2	1	2026-10-09 10:30:00+07	2026-10-10 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.186734+07	2026-09-26 16:41:08.186734+07	\N	\N	\N	\N	\N	2026-10-09
1596	2	1	2026-10-10 10:30:00+07	2026-10-11 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.300235+07	2026-09-26 16:41:08.300235+07	\N	\N	\N	\N	\N	2026-10-10
1597	2	1	2026-10-11 10:30:00+07	2026-10-12 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.300235+07	2026-09-26 16:41:08.300235+07	\N	\N	\N	\N	\N	2026-10-11
1598	2	1	2026-10-12 10:30:00+07	2026-10-13 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.300235+07	2026-09-26 16:41:08.300235+07	\N	\N	\N	\N	\N	2026-10-12
1599	2	1	2026-10-13 10:30:00+07	2026-10-14 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.548289+07	2026-09-26 16:41:08.548289+07	\N	\N	\N	\N	\N	2026-10-13
1600	2	1	2026-10-14 10:30:00+07	2026-10-15 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.668545+07	2026-09-26 16:41:08.668545+07	\N	\N	\N	\N	\N	2026-10-14
1601	2	1	2026-10-15 10:30:00+07	2026-10-16 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.77832+07	2026-09-26 16:41:08.77832+07	\N	\N	\N	\N	\N	2026-10-15
1602	2	1	2026-10-16 10:30:00+07	2026-10-17 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:08.897063+07	2026-09-26 16:41:08.897063+07	\N	\N	\N	\N	\N	2026-10-16
1603	2	1	2026-10-17 10:30:00+07	2026-10-18 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.014745+07	2026-09-26 16:41:09.014745+07	\N	\N	\N	\N	\N	2026-10-17
1604	2	1	2026-10-18 10:30:00+07	2026-10-19 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.014745+07	2026-09-26 16:41:09.014745+07	\N	\N	\N	\N	\N	2026-10-18
1605	2	1	2026-10-19 10:30:00+07	2026-10-20 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.014745+07	2026-09-26 16:41:09.014745+07	\N	\N	\N	\N	\N	2026-10-19
1606	2	1	2026-10-20 10:30:00+07	2026-10-21 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.23612+07	2026-09-26 16:41:09.23612+07	\N	\N	\N	\N	\N	2026-10-20
1607	2	1	2026-10-21 10:30:00+07	2026-10-22 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.356809+07	2026-09-26 16:41:09.356809+07	\N	\N	\N	\N	\N	2026-10-21
1608	2	1	2026-10-22 10:30:00+07	2026-10-23 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.47843+07	2026-09-26 16:41:09.47843+07	\N	\N	\N	\N	\N	2026-10-22
1609	2	1	2026-10-23 10:30:00+07	2026-10-24 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.602216+07	2026-09-26 16:41:09.602216+07	\N	\N	\N	\N	\N	2026-10-23
1610	2	1	2026-10-24 10:30:00+07	2026-10-25 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.725591+07	2026-09-26 16:41:09.725591+07	\N	\N	\N	\N	\N	2026-10-24
1611	2	1	2026-10-25 10:30:00+07	2026-10-26 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.725591+07	2026-09-26 16:41:09.725591+07	\N	\N	\N	\N	\N	2026-10-25
1612	2	1	2026-10-26 10:30:00+07	2026-10-27 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.725591+07	2026-09-26 16:41:09.725591+07	\N	\N	\N	\N	\N	2026-10-26
1613	2	1	2026-10-27 10:30:00+07	2026-10-28 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:09.951847+07	2026-09-26 16:41:09.951847+07	\N	\N	\N	\N	\N	2026-10-27
1614	2	1	2026-10-28 10:30:00+07	2026-10-29 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:10.077238+07	2026-09-26 16:41:10.077238+07	\N	\N	\N	\N	\N	2026-10-28
1615	2	1	2026-10-29 10:30:00+07	2026-10-30 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:10.196619+07	2026-09-26 16:41:10.196619+07	\N	\N	\N	\N	\N	2026-10-29
1616	2	1	2026-10-30 10:30:00+07	2026-10-31 10:30:00+07	draft	1	\N	\N	\N	2026-09-26 16:41:10.324459+07	2026-09-26 16:41:10.324459+07	\N	\N	\N	\N	\N	2026-10-30
1617	5	1	2026-11-03 10:00:00+07	2026-11-04 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:58.757826+07	2026-09-26 16:45:58.757826+07	\N	\N	\N	\N	\N	2026-11-03
1618	5	1	2026-11-04 10:00:00+07	2026-11-05 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:58.870796+07	2026-09-26 16:45:58.870796+07	\N	\N	\N	\N	\N	2026-11-04
1619	5	1	2026-11-05 10:00:00+07	2026-11-06 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:58.870796+07	2026-09-26 16:45:58.870796+07	\N	\N	\N	\N	\N	2026-11-05
1620	5	1	2026-11-06 10:00:00+07	2026-11-07 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.014572+07	2026-09-26 16:45:59.014572+07	\N	\N	\N	\N	\N	2026-11-06
1621	5	1	2026-11-07 10:00:00+07	2026-11-08 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.130721+07	2026-09-26 16:45:59.130721+07	\N	\N	\N	\N	\N	2026-11-07
1622	5	1	2026-11-08 10:00:00+07	2026-11-09 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.130721+07	2026-09-26 16:45:59.130721+07	\N	\N	\N	\N	\N	2026-11-08
1623	5	1	2026-11-09 10:00:00+07	2026-11-10 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.130721+07	2026-09-26 16:45:59.130721+07	\N	\N	\N	\N	\N	2026-11-09
1624	5	1	2026-11-10 10:00:00+07	2026-11-11 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.30354+07	2026-09-26 16:45:59.30354+07	\N	\N	\N	\N	\N	2026-11-10
1625	5	1	2026-11-11 10:00:00+07	2026-11-12 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.399643+07	2026-09-26 16:45:59.399643+07	\N	\N	\N	\N	\N	2026-11-11
1626	5	1	2026-11-12 10:00:00+07	2026-11-13 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.497463+07	2026-09-26 16:45:59.497463+07	\N	\N	\N	\N	\N	2026-11-12
1627	5	1	2026-11-13 10:00:00+07	2026-11-14 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.611549+07	2026-09-26 16:45:59.611549+07	\N	\N	\N	\N	\N	2026-11-13
1628	5	1	2026-11-14 10:00:00+07	2026-11-15 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.709501+07	2026-09-26 16:45:59.709501+07	\N	\N	\N	\N	\N	2026-11-14
1629	5	1	2026-11-15 10:00:00+07	2026-11-16 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.709501+07	2026-09-26 16:45:59.709501+07	\N	\N	\N	\N	\N	2026-11-15
1630	5	1	2026-11-16 10:00:00+07	2026-11-17 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.709501+07	2026-09-26 16:45:59.709501+07	\N	\N	\N	\N	\N	2026-11-16
1631	5	1	2026-11-17 10:00:00+07	2026-11-18 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.880101+07	2026-09-26 16:45:59.880101+07	\N	\N	\N	\N	\N	2026-11-17
1632	5	1	2026-11-18 10:00:00+07	2026-11-19 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:45:59.984671+07	2026-09-26 16:45:59.984671+07	\N	\N	\N	\N	\N	2026-11-18
1633	5	1	2026-11-19 10:00:00+07	2026-11-20 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.084805+07	2026-09-26 16:46:00.084805+07	\N	\N	\N	\N	\N	2026-11-19
1634	5	1	2026-11-20 10:00:00+07	2026-11-21 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.183285+07	2026-09-26 16:46:00.183285+07	\N	\N	\N	\N	\N	2026-11-20
1635	5	1	2026-11-21 10:00:00+07	2026-11-22 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.281816+07	2026-09-26 16:46:00.281816+07	\N	\N	\N	\N	\N	2026-11-21
1636	5	1	2026-11-22 10:00:00+07	2026-11-23 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.281816+07	2026-09-26 16:46:00.281816+07	\N	\N	\N	\N	\N	2026-11-22
1637	5	1	2026-11-23 10:00:00+07	2026-11-24 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.281816+07	2026-09-26 16:46:00.281816+07	\N	\N	\N	\N	\N	2026-11-23
1638	5	1	2026-11-24 10:00:00+07	2026-11-25 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.458233+07	2026-09-26 16:46:00.458233+07	\N	\N	\N	\N	\N	2026-11-24
1639	5	1	2026-11-25 10:00:00+07	2026-11-26 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.557391+07	2026-09-26 16:46:00.557391+07	\N	\N	\N	\N	\N	2026-11-25
1640	5	1	2026-11-26 10:00:00+07	2026-11-27 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.657293+07	2026-09-26 16:46:00.657293+07	\N	\N	\N	\N	\N	2026-11-26
1641	5	1	2026-11-27 10:00:00+07	2026-11-28 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.761782+07	2026-09-26 16:46:00.761782+07	\N	\N	\N	\N	\N	2026-11-27
1642	5	1	2026-11-28 10:00:00+07	2026-11-29 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.861661+07	2026-09-26 16:46:00.861661+07	\N	\N	\N	\N	\N	2026-11-28
1643	5	1	2026-11-29 10:00:00+07	2026-11-30 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.861661+07	2026-09-26 16:46:00.861661+07	\N	\N	\N	\N	\N	2026-11-29
1644	5	1	2026-11-30 10:00:00+07	2026-12-01 10:00:00+07	draft	1	\N	\N	\N	2026-09-26 16:46:00.861661+07	2026-09-26 16:46:00.861661+07	\N	\N	\N	\N	\N	2026-11-30
380	2	1	2026-09-30 10:30:00+07	2026-10-01 10:30:00+07	approved	\N	1	2026-09-27 14:32:10.627489+07	\N	2026-09-07 14:47:54.050619+07	2026-09-27 14:32:10.627489+07	\N	\N	{"duty": {"id": 380, "note": null, "status": "approved", "ends_at": "2026-10-01T03:30:00.000Z", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-30T03:30:00.000Z", "unit_name": "В/Ч 00011", "unit_short": "в/ч 00011", "duty_type_id": 2, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 138, "rank_id": 12, "unit_id": 5, "position": "начальник службы", "full_name": "Цветков Дмитрий Фёдорович", "last_name": "Цветков", "rank_name": "капитан", "seniority": 120, "first_name": "Дмитрий", "rank_short": "к-н", "short_name": "к-н Цветков Д.Ф.", "unit_short": "ТС", "middle_name": "Фёдорович", "personnel_number": "С-01098"}, "isOverride": false, "assignmentId": 3211, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 105, "rank_id": 8, "unit_id": 5, "position": "техник", "full_name": "Абрамов Борис Романович", "last_name": "Абрамов", "rank_name": "старший прапорщик", "seniority": 80, "first_name": "Борис", "rank_short": "ст. пр-к", "short_name": "ст. пр-к Абрамов Б.Р.", "unit_short": "ТС", "middle_name": "Романович", "personnel_number": "С-01065"}, "isOverride": false, "assignmentId": 3212, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 87, "rank_id": 6, "unit_id": 10, "position": "командир отделения", "full_name": "Панкратов Борис Романович", "last_name": "Панкратов", "rank_name": "старшина", "seniority": 60, "first_name": "Борис", "rank_short": "ст-на", "short_name": "ст-на Панкратов Б.Р.", "unit_short": "2 взвод", "middle_name": "Романович", "personnel_number": "С-01047"}, "isOverride": false, "assignmentId": 3213, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 70, "rank_id": 3, "unit_id": 15, "position": "Заместитель командира отделения", "full_name": "Абрамов Игорь Игоревич", "last_name": "Абрамов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Игорь", "rank_short": "мл. с-т", "short_name": "мл. с-т Абрамов И.И.", "unit_short": "1 отделение", "middle_name": "Игоревич", "personnel_number": "С-01030"}, "isOverride": false, "assignmentId": 3214, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 43, "rank_id": 1, "unit_id": 28, "position": "Наводчик-оператор", "full_name": "Цветков Тимур Тимурович", "last_name": "Цветков", "rank_name": "рядовой", "seniority": 10, "first_name": "Тимур", "rank_short": "р-й", "short_name": "р-й Цветков Т.Т.", "unit_short": "2 отделение", "middle_name": "Тимурович", "personnel_number": "С-01003"}, "isOverride": false, "assignmentId": 3215, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 45, "rank_id": 1, "unit_id": 29, "position": "Наводчик-оператор", "full_name": "Абрамов Кирилл Борисович", "last_name": "Абрамов", "rank_name": "рядовой", "seniority": 10, "first_name": "Кирилл", "rank_short": "р-й", "short_name": "р-й Абрамов К.Б.", "unit_short": "3 отделение", "middle_name": "Борисович", "personnel_number": "С-01005"}, "isOverride": false, "assignmentId": 3216, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 42, "rank_id": 1, "unit_id": 19, "position": "Наводчик-оператор", "full_name": "Панкратов Николай Дмитриевич", "last_name": "Панкратов", "rank_name": "рядовой", "seniority": 10, "first_name": "Николай", "rank_short": "р-й", "short_name": "р-й Панкратов Н.Д.", "unit_short": "2 отделение", "middle_name": "Дмитриевич", "personnel_number": "С-01002"}, "isOverride": false, "assignmentId": 3217, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 46, "rank_id": 1, "unit_id": 12, "position": "Механик-водитель", "full_name": "Зотов Павел Павлович", "last_name": "Зотов", "rank_name": "рядовой", "seniority": 10, "first_name": "Павел", "rank_short": "р-й", "short_name": "р-й Зотов П.П.", "unit_short": "1 отделение", "middle_name": "Павлович", "personnel_number": "С-01006"}, "isOverride": false, "assignmentId": 3218, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 19, "rank_id": 6, "unit_id": 5, "position": "радиотелефонист", "full_name": "Ушаков Григорий Кириллович", "last_name": "Ушаков", "rank_name": "старшина", "seniority": 60, "first_name": "Григорий", "rank_short": "ст-на", "short_name": "ст-на Ушаков Г.К.", "unit_short": "ТС", "middle_name": "Кириллович", "personnel_number": "Т-0019"}, "isOverride": false, "assignmentId": 3219, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 37, "rank_id": 1, "unit_id": 18, "position": "Наводчик-оператор", "full_name": "Крылов Евгений Борисович", "last_name": "Крылов", "rank_name": "рядовой", "seniority": 10, "first_name": "Евгений", "rank_short": "р-й", "short_name": "р-й Крылов Е.Б.", "unit_short": "1 отделение", "middle_name": "Борисович", "personnel_number": "Т-0037"}, "isOverride": false, "assignmentId": 3220, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 55, "rank_id": 2, "unit_id": 25, "position": "Заместитель командира отделения", "full_name": "Абрамов Геннадий Геннадьевич", "last_name": "Абрамов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Геннадий", "rank_short": "ефр.", "short_name": "ефр. Абрамов Г.Г.", "unit_short": "2 отделение", "middle_name": "Геннадьевич", "personnel_number": "С-01015"}, "isOverride": false, "assignmentId": 3221, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 41, "rank_id": 1, "unit_id": 27, "position": "Наводчик-оператор", "full_name": "Зотов Евгений Олегович", "last_name": "Зотов", "rank_name": "рядовой", "seniority": 10, "first_name": "Евгений", "rank_short": "р-й", "short_name": "р-й Зотов Е.О.", "unit_short": "1 отделение", "middle_name": "Олегович", "personnel_number": "С-01001"}, "isOverride": false, "assignmentId": 3222, "overrideReason": null}], "postCount": 12, "brokenCount": 0}	{"context": {"unit": "В/Ч 00011", "commander": {"last_name": "Зотов", "rank_name": "полковник", "first_name": "Олег", "middle_name": "Юрьевич"}}, "dutyType": {"code": "SN", "name": "Суточный наряд"}, "sections": [{"duty": {"id": 380, "note": null, "status": "approved", "ends_at": "2026-10-01T03:30:00.000Z", "unit_id": 1, "duty_code": "SN", "duty_name": "Суточный наряд", "starts_at": "2026-09-30T03:30:00.000Z", "unit_name": "В/Ч 00011", "unit_short": "в/ч 00011", "duty_type_id": 2, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 6, "name": "Дежурный по части", "short_name": "ДЧ", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 138, "rank_id": 12, "unit_id": 5, "position": "начальник службы", "full_name": "Цветков Дмитрий Фёдорович", "last_name": "Цветков", "rank_name": "капитан", "seniority": 120, "first_name": "Дмитрий", "rank_short": "к-н", "short_name": "к-н Цветков Д.Ф.", "unit_short": "ТС", "middle_name": "Фёдорович", "personnel_number": "С-01098"}, "isOverride": false, "assignmentId": 3211, "overrideReason": null}, {"note": null, "post": {"id": 7, "name": "Помощник дежурного по части", "short_name": "ПДЧ", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 105, "rank_id": 8, "unit_id": 5, "position": "техник", "full_name": "Абрамов Борис Романович", "last_name": "Абрамов", "rank_name": "старший прапорщик", "seniority": 80, "first_name": "Борис", "rank_short": "ст. пр-к", "short_name": "ст. пр-к Абрамов Б.Р.", "unit_short": "ТС", "middle_name": "Романович", "personnel_number": "С-01065"}, "isOverride": false, "assignmentId": 3212, "overrideReason": null}, {"note": null, "post": {"id": 13, "name": "Дежурный по 1-й роте", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 87, "rank_id": 6, "unit_id": 10, "position": "командир отделения", "full_name": "Панкратов Борис Романович", "last_name": "Панкратов", "rank_name": "старшина", "seniority": 60, "first_name": "Борис", "rank_short": "ст-на", "short_name": "ст-на Панкратов Б.Р.", "unit_short": "2 взвод", "middle_name": "Романович", "personnel_number": "С-01047"}, "isOverride": false, "assignmentId": 3213, "overrideReason": null}, {"note": null, "post": {"id": 12, "name": "Дежурный по 2-й роте", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 70, "rank_id": 3, "unit_id": 15, "position": "Заместитель командира отделения", "full_name": "Абрамов Игорь Игоревич", "last_name": "Абрамов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Игорь", "rank_short": "мл. с-т", "short_name": "мл. с-т Абрамов И.И.", "unit_short": "1 отделение", "middle_name": "Игоревич", "personnel_number": "С-01030"}, "isOverride": false, "assignmentId": 3214, "overrideReason": null}, {"note": null, "post": {"id": 16, "name": "Дневальный по 1-й роте — 1", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 43, "rank_id": 1, "unit_id": 28, "position": "Наводчик-оператор", "full_name": "Цветков Тимур Тимурович", "last_name": "Цветков", "rank_name": "рядовой", "seniority": 10, "first_name": "Тимур", "rank_short": "р-й", "short_name": "р-й Цветков Т.Т.", "unit_short": "2 отделение", "middle_name": "Тимурович", "personnel_number": "С-01003"}, "isOverride": false, "assignmentId": 3215, "overrideReason": null}, {"note": null, "post": {"id": 17, "name": "Дневальный по 1-й роте — 2", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 45, "rank_id": 1, "unit_id": 29, "position": "Наводчик-оператор", "full_name": "Абрамов Кирилл Борисович", "last_name": "Абрамов", "rank_name": "рядовой", "seniority": 10, "first_name": "Кирилл", "rank_short": "р-й", "short_name": "р-й Абрамов К.Б.", "unit_short": "3 отделение", "middle_name": "Борисович", "personnel_number": "С-01005"}, "isOverride": false, "assignmentId": 3216, "overrideReason": null}, {"note": null, "post": {"id": 14, "name": "Дневальный по 2-й роте — 1", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 42, "rank_id": 1, "unit_id": 19, "position": "Наводчик-оператор", "full_name": "Панкратов Николай Дмитриевич", "last_name": "Панкратов", "rank_name": "рядовой", "seniority": 10, "first_name": "Николай", "rank_short": "р-й", "short_name": "р-й Панкратов Н.Д.", "unit_short": "2 отделение", "middle_name": "Дмитриевич", "personnel_number": "С-01002"}, "isOverride": false, "assignmentId": 3217, "overrideReason": null}, {"note": null, "post": {"id": 15, "name": "Дневальный по 2-й роте — 2", "short_name": null, "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 46, "rank_id": 1, "unit_id": 12, "position": "Механик-водитель", "full_name": "Зотов Павел Павлович", "last_name": "Зотов", "rank_name": "рядовой", "seniority": 10, "first_name": "Павел", "rank_short": "р-й", "short_name": "р-й Зотов П.П.", "unit_short": "1 отделение", "middle_name": "Павлович", "personnel_number": "С-01006"}, "isOverride": false, "assignmentId": 3218, "overrideReason": null}, {"note": null, "post": {"id": 8, "name": "Дежурный по КПП", "short_name": "ДКПП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 19, "rank_id": 6, "unit_id": 5, "position": "радиотелефонист", "full_name": "Ушаков Григорий Кириллович", "last_name": "Ушаков", "rank_name": "старшина", "seniority": 60, "first_name": "Григорий", "rank_short": "ст-на", "short_name": "ст-на Ушаков Г.К.", "unit_short": "ТС", "middle_name": "Кириллович", "personnel_number": "Т-0019"}, "isOverride": false, "assignmentId": 3219, "overrideReason": null}, {"note": null, "post": {"id": 9, "name": "Помощник дежурного по КПП", "short_name": "ПДКПП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 37, "rank_id": 1, "unit_id": 18, "position": "Наводчик-оператор", "full_name": "Крылов Евгений Борисович", "last_name": "Крылов", "rank_name": "рядовой", "seniority": 10, "first_name": "Евгений", "rank_short": "р-й", "short_name": "р-й Крылов Е.Б.", "unit_short": "1 отделение", "middle_name": "Борисович", "personnel_number": "Т-0037"}, "isOverride": false, "assignmentId": 3220, "overrideReason": null}, {"note": null, "post": {"id": 10, "name": "Дежурный по парку", "short_name": "ДП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 55, "rank_id": 2, "unit_id": 25, "position": "Заместитель командира отделения", "full_name": "Абрамов Геннадий Геннадьевич", "last_name": "Абрамов", "rank_name": "ефрейтор", "seniority": 20, "first_name": "Геннадий", "rank_short": "ефр.", "short_name": "ефр. Абрамов Г.Г.", "unit_short": "2 отделение", "middle_name": "Геннадьевич", "personnel_number": "С-01015"}, "isOverride": false, "assignmentId": 3221, "overrideReason": null}, {"note": null, "post": {"id": 11, "name": "Помощник дежурного по парку", "short_name": "ПДП", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 41, "rank_id": 1, "unit_id": 27, "position": "Наводчик-оператор", "full_name": "Зотов Евгений Олегович", "last_name": "Зотов", "rank_name": "рядовой", "seniority": 10, "first_name": "Евгений", "rank_short": "р-й", "short_name": "р-й Зотов Е.О.", "unit_short": "1 отделение", "middle_name": "Олегович", "personnel_number": "С-01001"}, "isOverride": false, "assignmentId": 3222, "overrideReason": null}], "postCount": 12, "brokenCount": 0}], "template": {"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Закрепить за личным составом на время несения дежурства следующее оружие:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "Командир {{часть}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}]}, "unitName": "В/Ч 00011", "orderDate": "2026-09-29", "totalAssigned": 12, "templateVersion": 4}	2026-09-29	2026-09-30
410	3	1	2026-09-30 10:00:00+07	2026-10-01 10:00:00+07	approved	\N	1	2026-09-27 14:55:29.379437+07	\N	2026-09-07 14:47:54.209016+07	2026-09-27 14:55:29.379437+07	1	2026-09-11 23:31:51.758064+07	{"duty": {"id": 410, "note": null, "status": "approved", "ends_at": "2026-10-01T03:00:00.000Z", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-30T03:00:00.000Z", "unit_name": "В/Ч 00011", "unit_short": "в/ч 00011", "duty_type_id": 3, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 145, "rank_id": 13, "unit_id": 33, "position": "начальник службы", "full_name": "Абрамов Геннадий Геннадьевич", "last_name": "Абрамов", "rank_name": "майор", "seniority": 130, "first_name": "Геннадий", "rank_short": "м-р", "short_name": "м-р Абрамов Г.Г.", "unit_short": "Управление", "middle_name": "Геннадьевич", "personnel_number": "С-01105"}, "isOverride": false, "assignmentId": 3368, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 142, "rank_id": 12, "unit_id": 33, "position": "начальник службы", "full_name": "Панкратов Игорь Игоревич", "last_name": "Панкратов", "rank_name": "капитан", "seniority": 120, "first_name": "Игорь", "rank_short": "к-н", "short_name": "к-н Панкратов И.И.", "unit_short": "Управление", "middle_name": "Игоревич", "personnel_number": "С-01102"}, "isOverride": false, "assignmentId": 3378, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 112, "rank_id": 9, "unit_id": 4, "position": "командир взвода", "full_name": "Панкратов Александр Александрович", "last_name": "Панкратов", "rank_name": "младший лейтенант", "seniority": 90, "first_name": "Александр", "rank_short": "мл. л-т", "short_name": "мл. л-т Панкратов А.А.", "unit_short": "УС", "middle_name": "Александрович", "personnel_number": "С-01072"}, "isOverride": false, "assignmentId": 3370, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 95, "rank_id": 7, "unit_id": 5, "position": "техник", "full_name": "Абрамов Евгений Олегович", "last_name": "Абрамов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Евгений", "rank_short": "пр-к", "short_name": "пр-к Абрамов Е.О.", "unit_short": "ТС", "middle_name": "Олегович", "personnel_number": "С-01055"}, "isOverride": false, "assignmentId": 6522, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 71, "rank_id": 3, "unit_id": 24, "position": "Заместитель командира отделения", "full_name": "Зотов Олег Юрьевич", "last_name": "Зотов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Олег", "rank_short": "мл. с-т", "short_name": "мл. с-т Зотов О.Ю.", "unit_short": "1 отделение", "middle_name": "Юрьевич", "personnel_number": "С-01031"}, "isOverride": false, "assignmentId": 3372, "overrideReason": null}], "postCount": 5, "brokenCount": 0}	{"context": {"unit": "В/Ч 00011", "chief": {"title": "Начальник штаба", "acting": false, "last_name": "Кравцов", "rank_name": "подполковник", "first_name": "Олег", "middle_name": "Николаевич"}, "commander": {"title": "Командир части", "acting": false, "last_name": "Абрамов", "rank_name": "полковник", "first_name": "Роман", "middle_name": "Кириллович"}}, "dutyType": {"code": "OD", "name": "Оперативное дежурство"}, "sections": [{"duty": {"id": 410, "note": null, "status": "approved", "ends_at": "2026-10-01T03:00:00.000Z", "unit_id": 1, "duty_code": "OD", "duty_name": "Оперативное дежурство", "starts_at": "2026-09-30T03:00:00.000Z", "unit_name": "В/Ч 00011", "unit_short": "в/ч 00011", "duty_type_id": 3, "order_deadline": null}, "roster": [{"note": null, "post": {"id": 1, "name": "Оперативный дежурный", "short_name": "ОД", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 145, "rank_id": 13, "unit_id": 33, "position": "начальник службы", "full_name": "Абрамов Геннадий Геннадьевич", "last_name": "Абрамов", "rank_name": "майор", "seniority": 130, "first_name": "Геннадий", "rank_short": "м-р", "short_name": "м-р Абрамов Г.Г.", "unit_short": "Управление", "middle_name": "Геннадьевич", "personnel_number": "С-01105"}, "isOverride": false, "assignmentId": 3368, "overrideReason": null}, {"note": null, "post": {"id": 2, "name": "Старший помощник оперативного дежурного", "short_name": "СПОД", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 142, "rank_id": 12, "unit_id": 33, "position": "начальник службы", "full_name": "Панкратов Игорь Игоревич", "last_name": "Панкратов", "rank_name": "капитан", "seniority": 120, "first_name": "Игорь", "rank_short": "к-н", "short_name": "к-н Панкратов И.И.", "unit_short": "Управление", "middle_name": "Игоревич", "personnel_number": "С-01102"}, "isOverride": false, "assignmentId": 3378, "overrideReason": null}, {"note": null, "post": {"id": 3, "name": "Помощник оперативного дежурного", "short_name": "ПОД", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 112, "rank_id": 9, "unit_id": 4, "position": "командир взвода", "full_name": "Панкратов Александр Александрович", "last_name": "Панкратов", "rank_name": "младший лейтенант", "seniority": 90, "first_name": "Александр", "rank_short": "мл. л-т", "short_name": "мл. л-т Панкратов А.А.", "unit_short": "УС", "middle_name": "Александрович", "personnel_number": "С-01072"}, "isOverride": false, "assignmentId": 3370, "overrideReason": null}, {"note": null, "post": {"id": 4, "name": "Старший оператор", "short_name": "СО", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 95, "rank_id": 7, "unit_id": 5, "position": "техник", "full_name": "Абрамов Евгений Олегович", "last_name": "Абрамов", "rank_name": "прапорщик", "seniority": 70, "first_name": "Евгений", "rank_short": "пр-к", "short_name": "пр-к Абрамов Е.О.", "unit_short": "ТС", "middle_name": "Олегович", "personnel_number": "С-01055"}, "isOverride": false, "assignmentId": 6522, "overrideReason": null}, {"note": null, "post": {"id": 5, "name": "Оператор", "short_name": "О", "start_time": null, "duration_hours": null}, "broken": null, "onDate": null, "weapon": null, "employee": {"id": 71, "rank_id": 3, "unit_id": 24, "position": "Заместитель командира отделения", "full_name": "Зотов Олег Юрьевич", "last_name": "Зотов", "rank_name": "младший сержант", "seniority": 30, "first_name": "Олег", "rank_short": "мл. с-т", "short_name": "мл. с-т Зотов О.Ю.", "unit_short": "1 отделение", "middle_name": "Юрьевич", "personnel_number": "С-01031"}, "isOverride": false, "assignmentId": 3372, "overrideReason": null}], "postCount": 5, "brokenCount": 0}], "template": {"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "{{командир_должность}}\\n{{командир_звание}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}, {"bold": false, "kind": "signature", "text": "{{начальник_штаба_должность}}\\n{{начальник_штаба_звание}}", "align": "left", "posts": [], "right": "{{начальник_штаба}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 18}]}, "unitName": "В/Ч 00011", "orderDate": "2026-09-29", "totalAssigned": 5, "templateVersion": 0}	2026-09-29	2026-09-30
\.


--
-- Data for Name: duty_assignments; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.duty_assignments (id, duty_id, employee_id, is_override, override_reason, override_by, created_at, post_id, source, note, noted_by, noted_at, override_checks, on_date, weapon_id) FROM stdin;
16352	1510	23	f	\N	\N	2026-09-20 19:05:20.181814+07	33	auto	\N	\N	\N	{}	\N	\N
2791	342	22	f	\N	\N	2026-09-07 14:47:53.749227+07	18	manual	\N	\N	\N	{}	\N	\N
3	2	7	f	\N	\N	2026-08-24 15:38:50.300274+07	6	manual	\N	\N	\N	{}	\N	\N
4	2	34	f	\N	\N	2026-08-24 15:38:50.300274+07	7	manual	\N	\N	\N	{}	\N	\N
5	2	16	f	\N	\N	2026-08-24 15:38:50.300274+07	13	manual	\N	\N	\N	{}	\N	\N
6	2	9	f	\N	\N	2026-08-24 15:38:50.300274+07	12	manual	\N	\N	\N	{}	\N	\N
7	2	4	f	\N	\N	2026-08-24 15:38:50.300274+07	17	manual	\N	\N	\N	{}	\N	\N
8	2	5	f	\N	\N	2026-08-24 15:38:50.300274+07	15	manual	\N	\N	\N	{}	\N	\N
9	2	6	f	\N	\N	2026-08-24 15:38:50.300274+07	8	manual	\N	\N	\N	{}	\N	\N
10	2	18	f	\N	\N	2026-08-24 15:38:50.300274+07	9	manual	\N	\N	\N	{}	\N	\N
11	2	35	f	\N	\N	2026-08-24 15:38:50.300274+07	10	manual	\N	\N	\N	{}	\N	\N
12	2	17	f	\N	\N	2026-08-24 15:38:50.300274+07	11	manual	\N	\N	\N	{}	\N	\N
2792	342	111	f	\N	\N	2026-09-07 14:47:53.749227+07	19	manual	\N	\N	\N	{}	\N	\N
2793	342	8	f	\N	\N	2026-09-07 14:47:53.749227+07	20	manual	\N	\N	\N	{}	\N	\N
2794	342	2	f	\N	\N	2026-09-07 14:47:53.749227+07	21	manual	\N	\N	\N	{}	\N	\N
2795	342	12	f	\N	\N	2026-09-07 14:47:53.749227+07	22	manual	\N	\N	\N	{}	\N	\N
2796	342	15	f	\N	\N	2026-09-07 14:47:53.749227+07	23	manual	\N	\N	\N	{}	\N	\N
2797	342	24	f	\N	\N	2026-09-07 14:47:53.749227+07	24	manual	\N	\N	\N	{}	\N	\N
2798	342	25	f	\N	\N	2026-09-07 14:47:53.749227+07	25	manual	\N	\N	\N	{}	\N	\N
2831	347	123	f	\N	\N	2026-09-07 14:47:53.78681+07	18	manual	\N	\N	\N	{}	\N	\N
2832	347	124	f	\N	\N	2026-09-07 14:47:53.78681+07	19	manual	\N	\N	\N	{}	\N	\N
2833	347	96	f	\N	\N	2026-09-07 14:47:53.78681+07	20	manual	\N	\N	\N	{}	\N	\N
2834	347	27	f	\N	\N	2026-09-07 14:47:53.78681+07	21	manual	\N	\N	\N	{}	\N	\N
2835	347	19	f	\N	\N	2026-09-07 14:47:53.78681+07	22	manual	\N	\N	\N	{}	\N	\N
2836	347	26	f	\N	\N	2026-09-07 14:47:53.78681+07	23	manual	\N	\N	\N	{}	\N	\N
2837	347	25	f	\N	\N	2026-09-07 14:47:53.78681+07	24	manual	\N	\N	\N	{}	\N	\N
2838	347	4	f	\N	\N	2026-09-07 14:47:53.78681+07	25	manual	\N	\N	\N	{}	\N	\N
3307	397	81	f	\N	\N	2026-09-07 14:47:54.139715+07	5	manual	\N	\N	\N	{}	\N	\N
3328	402	147	f	\N	\N	2026-09-07 14:47:54.16553+07	1	manual	\N	\N	\N	{}	\N	\N
3329	402	130	f	\N	\N	2026-09-07 14:47:54.16553+07	2	manual	\N	\N	\N	{}	\N	\N
3330	402	9	f	\N	\N	2026-09-07 14:47:54.16553+07	3	manual	\N	\N	\N	{}	\N	\N
3331	402	93	f	\N	\N	2026-09-07 14:47:54.16553+07	4	manual	\N	\N	\N	{}	\N	\N
3332	402	94	f	\N	\N	2026-09-07 14:47:54.16553+07	5	manual	\N	\N	\N	{}	\N	\N
3348	406	115	f	\N	\N	2026-09-07 14:47:54.187026+07	1	manual	\N	\N	\N	{}	\N	\N
3349	406	137	f	\N	\N	2026-09-07 14:47:54.187026+07	2	manual	\N	\N	\N	{}	\N	\N
3350	406	138	f	\N	\N	2026-09-07 14:47:54.187026+07	3	manual	\N	\N	\N	{}	\N	\N
3351	406	108	f	\N	\N	2026-09-07 14:47:54.187026+07	4	manual	\N	\N	\N	{}	\N	\N
3352	406	32	f	\N	\N	2026-09-07 14:47:54.187026+07	5	manual	\N	\N	\N	{}	\N	\N
16353	1511	33	f	\N	\N	2026-09-20 19:05:20.299447+07	33	auto	\N	\N	\N	{}	\N	\N
3382	407	121	f	\N	\N	2026-09-13 10:16:31.636412+07	3	manual	\N	\N	\N	{}	\N	\N
3383	408	8	f	\N	\N	2026-09-13 10:16:31.636412+07	4	manual	\N	\N	\N	{}	\N	\N
16354	1512	110	f	\N	\N	2026-09-20 19:05:20.380605+07	33	auto	\N	\N	\N	{}	\N	\N
16355	1513	116	f	\N	\N	2026-09-20 19:05:20.459356+07	33	auto	\N	\N	\N	{}	\N	\N
16356	1514	120	f	\N	\N	2026-09-20 19:05:20.537317+07	33	auto	\N	\N	\N	{}	\N	\N
16357	1515	122	f	\N	\N	2026-09-20 19:05:20.622891+07	33	auto	\N	\N	\N	{}	\N	\N
16358	1516	128	f	\N	\N	2026-09-20 19:05:20.622891+07	33	auto	\N	\N	\N	{}	\N	\N
16359	1517	134	f	\N	\N	2026-09-20 19:05:20.622891+07	33	auto	\N	\N	\N	{}	\N	\N
16360	1518	140	f	\N	\N	2026-09-20 19:05:20.749817+07	33	auto	\N	\N	\N	{}	\N	\N
16361	1519	146	f	\N	\N	2026-09-20 19:05:20.825698+07	33	auto	\N	\N	\N	{}	\N	\N
16362	1520	151	f	\N	\N	2026-09-20 19:05:23.204165+07	33	auto	\N	\N	\N	{}	\N	\N
16363	1521	152	f	\N	\N	2026-09-20 19:05:23.283467+07	33	auto	\N	\N	\N	{}	\N	\N
16364	1522	153	f	\N	\N	2026-09-20 19:05:23.364147+07	33	auto	\N	\N	\N	{}	\N	\N
16365	1523	154	f	\N	\N	2026-09-20 19:05:23.364147+07	33	auto	\N	\N	\N	{}	\N	\N
16366	1524	155	f	\N	\N	2026-09-20 19:05:23.364147+07	33	auto	\N	\N	\N	{}	\N	\N
16367	1525	156	f	\N	\N	2026-09-20 19:05:23.495449+07	33	auto	\N	\N	\N	{}	\N	\N
16368	1526	157	f	\N	\N	2026-09-20 19:05:23.582335+07	33	auto	\N	\N	\N	{}	\N	\N
16369	1527	158	f	\N	\N	2026-09-20 19:05:23.666764+07	33	auto	\N	\N	\N	{}	\N	\N
16370	1528	159	f	\N	\N	2026-09-20 19:05:23.746601+07	33	auto	\N	\N	\N	{}	\N	\N
16371	1529	160	f	\N	\N	2026-09-20 19:05:23.821376+07	33	auto	\N	\N	\N	{}	\N	\N
16372	1530	161	f	\N	\N	2026-09-20 19:05:23.821376+07	33	auto	\N	\N	\N	{}	\N	\N
16373	1531	162	f	\N	\N	2026-09-20 19:05:23.821376+07	33	auto	\N	\N	\N	{}	\N	\N
16374	1532	163	f	\N	\N	2026-09-20 19:05:23.949355+07	33	auto	\N	\N	\N	{}	\N	\N
16375	1533	164	f	\N	\N	2026-09-20 19:05:24.025907+07	33	auto	\N	\N	\N	{}	\N	\N
16376	1534	165	f	\N	\N	2026-09-20 19:05:24.102422+07	33	auto	\N	\N	\N	{}	\N	\N
16377	1535	166	f	\N	\N	2026-09-20 19:05:24.178346+07	33	auto	\N	\N	\N	{}	\N	\N
16378	1536	167	f	\N	\N	2026-09-20 19:05:24.255157+07	33	auto	\N	\N	\N	{}	\N	\N
16379	1537	168	f	\N	\N	2026-09-20 19:05:24.255157+07	33	auto	\N	\N	\N	{}	\N	\N
16380	1538	169	f	\N	\N	2026-09-20 19:05:24.255157+07	33	auto	\N	\N	\N	{}	\N	\N
16381	1539	170	f	\N	\N	2026-09-20 19:05:24.386167+07	33	auto	\N	\N	\N	{}	\N	\N
16382	1540	23	f	\N	\N	2026-09-20 19:05:24.462864+07	33	auto	\N	\N	\N	{}	\N	\N
16383	1541	33	f	\N	\N	2026-09-20 19:05:24.539225+07	33	auto	\N	\N	\N	{}	\N	\N
16384	1542	110	f	\N	\N	2026-09-20 19:05:24.614874+07	33	auto	\N	\N	\N	{}	\N	\N
16385	1543	116	f	\N	\N	2026-09-20 19:05:24.691714+07	33	auto	\N	\N	\N	{}	\N	\N
16386	1544	120	f	\N	\N	2026-09-20 19:05:24.691714+07	33	auto	\N	\N	\N	{}	\N	\N
16387	1545	122	f	\N	\N	2026-09-20 19:05:24.691714+07	33	auto	\N	\N	\N	{}	\N	\N
16388	1546	128	f	\N	\N	2026-09-20 19:05:24.824484+07	33	auto	\N	\N	\N	{}	\N	\N
16389	1547	134	f	\N	\N	2026-09-20 19:05:24.902495+07	33	auto	\N	\N	\N	{}	\N	\N
16390	1548	140	f	\N	\N	2026-09-20 19:05:24.986611+07	33	auto	\N	\N	\N	{}	\N	\N
16391	1549	35	f	\N	\N	2026-09-20 19:05:25.065173+07	33	auto	\N	\N	\N	{}	\N	\N
16392	1550	146	f	\N	\N	2026-09-20 19:05:25.143985+07	33	auto	\N	\N	\N	{}	\N	\N
16393	1551	151	f	\N	\N	2026-09-20 19:05:25.143985+07	33	auto	\N	\N	\N	{}	\N	\N
16394	1552	152	f	\N	\N	2026-09-20 19:05:25.143985+07	33	auto	\N	\N	\N	{}	\N	\N
3374	360	103	f	\N	\N	2026-09-07 15:33:44.23311+07	6	manual	\N	\N	\N	{}	\N	\N
2799	343	112	f	\N	\N	2026-09-07 14:47:53.758007+07	18	manual	\N	\N	\N	{}	\N	\N
2800	343	113	f	\N	\N	2026-09-07 14:47:53.758007+07	19	manual	\N	\N	\N	{}	\N	\N
2801	343	32	f	\N	\N	2026-09-07 14:47:53.758007+07	20	manual	\N	\N	\N	{}	\N	\N
2802	343	37	f	\N	\N	2026-09-07 14:47:53.758007+07	21	manual	\N	\N	\N	{}	\N	\N
2803	343	19	f	\N	\N	2026-09-07 14:47:53.758007+07	22	manual	\N	\N	\N	{}	\N	\N
2804	343	26	f	\N	\N	2026-09-07 14:47:53.758007+07	23	manual	\N	\N	\N	{}	\N	\N
2805	343	28	f	\N	\N	2026-09-07 14:47:53.758007+07	24	manual	\N	\N	\N	{}	\N	\N
2806	343	4	f	\N	\N	2026-09-07 14:47:53.758007+07	25	manual	\N	\N	\N	{}	\N	\N
2839	348	125	f	\N	\N	2026-09-07 14:47:53.79248+07	18	manual	\N	\N	\N	{}	\N	\N
2840	348	126	f	\N	\N	2026-09-07 14:47:53.79248+07	19	manual	\N	\N	\N	{}	\N	\N
2841	348	97	f	\N	\N	2026-09-07 14:47:53.79248+07	20	manual	\N	\N	\N	{}	\N	\N
2842	348	14	f	\N	\N	2026-09-07 14:47:53.79248+07	21	manual	\N	\N	\N	{}	\N	\N
2843	348	29	f	\N	\N	2026-09-07 14:47:53.79248+07	22	manual	\N	\N	\N	{}	\N	\N
2844	348	36	f	\N	\N	2026-09-07 14:47:53.79248+07	23	manual	\N	\N	\N	{}	\N	\N
2845	348	28	f	\N	\N	2026-09-07 14:47:53.79248+07	24	manual	\N	\N	\N	{}	\N	\N
2846	348	5	f	\N	\N	2026-09-07 14:47:53.79248+07	25	manual	\N	\N	\N	{}	\N	\N
3341	404	75	f	\N	\N	2026-09-07 14:47:54.17564+07	4	manual	\N	\N	\N	{}	\N	\N
3342	404	81	f	\N	\N	2026-09-07 14:47:54.17564+07	5	manual	\N	\N	\N	{}	\N	\N
3363	409	144	f	\N	\N	2026-09-07 14:47:54.203382+07	1	manual	\N	\N	\N	{}	\N	\N
3364	409	22	f	\N	\N	2026-09-07 14:47:54.203382+07	2	manual	\N	\N	\N	{}	\N	\N
3365	409	96	f	\N	\N	2026-09-07 14:47:54.203382+07	3	manual	\N	\N	\N	{}	\N	\N
3366	409	106	f	\N	\N	2026-09-07 14:47:54.203382+07	4	manual	\N	\N	\N	{}	\N	\N
3367	409	107	f	\N	\N	2026-09-07 14:47:54.203382+07	5	manual	\N	\N	\N	{}	\N	\N
3380	369	144	f	\N	\N	2026-09-11 22:17:20.454247+07	6	manual	заменен по болезни, приказ № 118 от 18.09.2026	1	2026-09-11 22:17:20.454247+07	{}	\N	\N
16397	1553	108	f	\N	\N	2026-09-20 19:35:16.66724+07	20	auto	\N	\N	\N	{}	\N	\N
16398	1553	2	f	\N	\N	2026-09-20 19:35:16.66724+07	21	auto	\N	\N	\N	{}	\N	\N
16399	1553	15	f	\N	\N	2026-09-20 19:35:16.66724+07	22	auto	\N	\N	\N	{}	\N	\N
16400	1553	39	f	\N	\N	2026-09-20 19:35:16.66724+07	23	auto	\N	\N	\N	{}	\N	\N
16401	1553	38	f	\N	\N	2026-09-20 19:35:16.66724+07	24	auto	\N	\N	\N	{}	\N	\N
16402	1553	27	f	\N	\N	2026-09-20 19:35:16.66724+07	25	auto	\N	\N	\N	{}	\N	\N
16403	1553	36	f	\N	\N	2026-09-20 19:35:16.66724+07	29	auto	\N	\N	\N	{}	\N	\N
16404	1553	49	f	\N	\N	2026-09-20 19:35:16.66724+07	30	auto	\N	\N	\N	{}	\N	\N
16405	1553	47	f	\N	\N	2026-09-20 19:35:16.66724+07	28	auto	\N	\N	\N	{}	2026-10-30	\N
16406	1553	48	f	\N	\N	2026-09-20 19:35:16.66724+07	27	auto	\N	\N	\N	{}	2026-10-31	\N
16407	1553	51	f	\N	\N	2026-09-20 19:35:16.66724+07	28	auto	\N	\N	\N	{}	2026-10-31	\N
16408	1553	53	f	\N	\N	2026-09-20 19:35:16.66724+07	27	auto	\N	\N	\N	{}	2026-11-01	\N
16409	1553	64	f	\N	\N	2026-09-20 19:35:16.66724+07	28	auto	\N	\N	\N	{}	2026-11-01	\N
16410	1553	12	f	\N	\N	2026-09-20 19:35:16.66724+07	27	auto	\N	\N	\N	{}	2026-11-02	\N
16411	1553	24	f	\N	\N	2026-09-20 19:35:16.66724+07	28	auto	\N	\N	\N	{}	2026-11-02	\N
16412	1553	25	f	\N	\N	2026-09-20 19:35:16.66724+07	27	auto	\N	\N	\N	{}	2026-11-03	\N
16415	1554	8	f	\N	\N	2026-09-20 19:35:16.92442+07	20	auto	\N	\N	\N	{}	\N	\N
16416	1554	19	f	\N	\N	2026-09-20 19:35:16.92442+07	21	auto	\N	\N	\N	{}	\N	\N
16417	1554	6	f	\N	\N	2026-09-20 19:35:16.92442+07	22	auto	\N	\N	\N	{}	\N	\N
16418	1554	14	f	\N	\N	2026-09-20 19:35:16.92442+07	23	auto	\N	\N	\N	{}	\N	\N
16419	1554	7	f	\N	\N	2026-09-20 19:35:16.92442+07	24	auto	\N	\N	\N	{}	\N	\N
16420	1554	18	f	\N	\N	2026-09-20 19:35:16.92442+07	25	auto	\N	\N	\N	{}	\N	\N
16421	1554	96	f	\N	\N	2026-09-20 19:35:16.92442+07	29	auto	\N	\N	\N	{}	\N	\N
16422	1554	102	f	\N	\N	2026-09-20 19:35:16.92442+07	30	auto	\N	\N	\N	{}	\N	\N
16423	1554	93	f	\N	\N	2026-09-20 19:35:16.92442+07	28	auto	\N	\N	\N	{}	2026-11-03	\N
16424	1554	32	f	\N	\N	2026-09-20 19:35:16.92442+07	27	auto	\N	\N	\N	{}	2026-11-04	\N
16425	1554	95	f	\N	\N	2026-09-20 19:35:16.92442+07	28	auto	\N	\N	\N	{}	2026-11-04	\N
16426	1554	107	f	\N	\N	2026-09-20 19:35:16.92442+07	27	auto	\N	\N	\N	{}	2026-11-05	\N
16427	1554	109	f	\N	\N	2026-09-20 19:35:16.92442+07	28	auto	\N	\N	\N	{}	2026-11-05	\N
16428	1554	89	f	\N	\N	2026-09-20 19:35:16.92442+07	27	auto	\N	\N	\N	{}	2026-11-06	\N
16431	1555	94	f	\N	\N	2026-09-20 19:35:17.146491+07	20	auto	\N	\N	\N	{}	\N	\N
16432	1555	2	f	\N	\N	2026-09-20 19:35:17.146491+07	21	auto	\N	\N	\N	{}	\N	\N
16433	1555	15	f	\N	\N	2026-09-20 19:35:17.146491+07	22	auto	\N	\N	\N	{}	\N	\N
16434	1555	27	f	\N	\N	2026-09-20 19:35:17.146491+07	23	auto	\N	\N	\N	{}	\N	\N
16435	1555	38	f	\N	\N	2026-09-20 19:35:17.146491+07	24	auto	\N	\N	\N	{}	\N	\N
16436	1555	39	f	\N	\N	2026-09-20 19:35:17.146491+07	25	auto	\N	\N	\N	{}	\N	\N
16437	1555	26	f	\N	\N	2026-09-20 19:35:17.146491+07	29	auto	\N	\N	\N	{}	\N	\N
16438	1555	97	f	\N	\N	2026-09-20 19:35:17.146491+07	30	auto	\N	\N	\N	{}	\N	\N
16439	1555	108	f	\N	\N	2026-09-20 19:35:17.146491+07	28	auto	\N	\N	\N	{}	2026-11-06	\N
16440	1555	47	f	\N	\N	2026-09-20 19:35:17.146491+07	27	auto	\N	\N	\N	{}	2026-11-07	\N
16441	1555	55	f	\N	\N	2026-09-20 19:35:17.146491+07	28	auto	\N	\N	\N	{}	2026-11-07	\N
16442	1555	57	f	\N	\N	2026-09-20 19:35:17.146491+07	27	auto	\N	\N	\N	{}	2026-11-08	\N
16443	1555	99	f	\N	\N	2026-09-20 19:35:17.146491+07	28	auto	\N	\N	\N	{}	2026-11-08	\N
16444	1555	41	f	\N	\N	2026-09-20 19:35:17.146491+07	27	auto	\N	\N	\N	{}	2026-11-09	\N
16445	1555	43	f	\N	\N	2026-09-20 19:35:17.146491+07	28	auto	\N	\N	\N	{}	2026-11-09	\N
16446	1555	45	f	\N	\N	2026-09-20 19:35:17.146491+07	27	auto	\N	\N	\N	{}	2026-11-10	\N
16449	1556	8	f	\N	\N	2026-09-20 19:35:17.409752+07	20	auto	\N	\N	\N	{}	\N	\N
16450	1556	6	f	\N	\N	2026-09-20 19:35:17.409752+07	21	auto	\N	\N	\N	{}	\N	\N
16451	1556	7	f	\N	\N	2026-09-20 19:35:17.409752+07	22	auto	\N	\N	\N	{}	\N	\N
16452	1556	14	f	\N	\N	2026-09-20 19:35:17.409752+07	23	auto	\N	\N	\N	{}	\N	\N
16453	1556	19	f	\N	\N	2026-09-20 19:35:17.409752+07	24	auto	\N	\N	\N	{}	\N	\N
16454	1556	18	f	\N	\N	2026-09-20 19:35:17.409752+07	25	auto	\N	\N	\N	{}	\N	\N
16455	1556	101	f	\N	\N	2026-09-20 19:35:17.409752+07	29	auto	\N	\N	\N	{}	\N	\N
16456	1556	103	f	\N	\N	2026-09-20 19:35:17.409752+07	30	auto	\N	\N	\N	{}	\N	\N
16457	1556	105	f	\N	\N	2026-09-20 19:35:17.409752+07	28	auto	\N	\N	\N	{}	2026-11-10	\N
16458	1556	106	f	\N	\N	2026-09-20 19:35:17.409752+07	27	auto	\N	\N	\N	{}	2026-11-11	\N
16459	1556	93	f	\N	\N	2026-09-20 19:35:17.409752+07	28	auto	\N	\N	\N	{}	2026-11-11	\N
16460	1556	32	f	\N	\N	2026-09-20 19:35:17.409752+07	27	auto	\N	\N	\N	{}	2026-11-12	\N
16461	1556	26	f	\N	\N	2026-09-20 19:35:17.409752+07	28	auto	\N	\N	\N	{}	2026-11-12	\N
16462	1556	81	f	\N	\N	2026-09-20 19:35:17.409752+07	27	auto	\N	\N	\N	{}	2026-11-13	\N
16465	1557	97	f	\N	\N	2026-09-20 19:35:17.624779+07	20	auto	\N	\N	\N	{}	\N	\N
3375	388	60	f	\N	\N	2026-09-07 15:37:23.259556+07	5	manual	\N	\N	\N	{}	\N	\N
3381	370	35	f	\N	\N	2026-09-11 22:22:58.949849+07	6	manual	\N	\N	\N	{}	\N	\N
2807	344	114	f	\N	\N	2026-09-07 14:47:53.764608+07	18	manual	\N	\N	\N	{}	\N	\N
2808	344	115	f	\N	\N	2026-09-07 14:47:53.764608+07	19	manual	\N	\N	\N	{}	\N	\N
2809	344	93	f	\N	\N	2026-09-07 14:47:53.764608+07	20	manual	\N	\N	\N	{}	\N	\N
2810	344	6	f	\N	\N	2026-09-07 14:47:53.764608+07	21	manual	\N	\N	\N	{}	\N	\N
2811	344	29	f	\N	\N	2026-09-07 14:47:53.764608+07	22	manual	\N	\N	\N	{}	\N	\N
2812	344	36	f	\N	\N	2026-09-07 14:47:53.764608+07	23	manual	\N	\N	\N	{}	\N	\N
2813	344	38	f	\N	\N	2026-09-07 14:47:53.764608+07	24	manual	\N	\N	\N	{}	\N	\N
2814	344	7	f	\N	\N	2026-09-07 14:47:53.764608+07	25	manual	\N	\N	\N	{}	\N	\N
2847	349	9	f	\N	\N	2026-09-07 14:47:53.798386+07	18	manual	\N	\N	\N	{}	\N	\N
2848	349	34	f	\N	\N	2026-09-07 14:47:53.798386+07	19	manual	\N	\N	\N	{}	\N	\N
2849	349	99	f	\N	\N	2026-09-07 14:47:53.798386+07	20	manual	\N	\N	\N	{}	\N	\N
2850	349	6	f	\N	\N	2026-09-07 14:47:53.798386+07	21	manual	\N	\N	\N	{}	\N	\N
2851	349	7	f	\N	\N	2026-09-07 14:47:53.798386+07	22	manual	\N	\N	\N	{}	\N	\N
2852	349	16	f	\N	\N	2026-09-07 14:47:53.798386+07	23	manual	\N	\N	\N	{}	\N	\N
2853	349	17	f	\N	\N	2026-09-07 14:47:53.798386+07	24	manual	\N	\N	\N	{}	\N	\N
2854	349	18	f	\N	\N	2026-09-07 14:47:53.798386+07	25	manual	\N	\N	\N	{}	\N	\N
3556	418	32	f	\N	\N	2026-09-13 11:09:46.136708+07	20	manual	\N	\N	\N	{}	\N	\N
3557	418	29	f	\N	\N	2026-09-13 11:09:46.136708+07	21	manual	\N	\N	\N	{}	\N	\N
3558	418	14	f	\N	\N	2026-09-13 11:09:46.136708+07	22	manual	\N	\N	\N	{}	\N	\N
3559	418	28	f	\N	\N	2026-09-13 11:09:46.136708+07	23	manual	\N	\N	\N	{}	\N	\N
3560	418	6	f	\N	\N	2026-09-13 11:09:46.136708+07	24	manual	\N	\N	\N	{}	\N	\N
3561	418	36	f	\N	\N	2026-09-13 11:09:46.136708+07	25	manual	\N	\N	\N	{}	\N	\N
3562	418	84	f	\N	\N	2026-09-13 11:09:46.136708+07	28	manual	\N	\N	\N	{}	2026-10-06	\N
3563	418	96	f	\N	\N	2026-09-13 11:09:46.136708+07	27	manual	\N	\N	\N	{}	2026-10-07	\N
3564	418	102	f	\N	\N	2026-09-13 11:09:46.136708+07	28	manual	\N	\N	\N	{}	2026-10-07	\N
3746	418	81	f	\N	\N	2026-09-13 11:27:58.786823+07	29	manual	\N	\N	\N	{}	\N	\N
3747	418	93	f	\N	\N	2026-09-13 11:27:58.786823+07	30	manual	\N	\N	\N	{}	\N	\N
3567	418	78	f	\N	\N	2026-09-13 11:09:46.136708+07	27	manual	\N	\N	\N	{}	2026-10-08	\N
3568	418	95	f	\N	\N	2026-09-13 11:09:46.136708+07	28	manual	\N	\N	\N	{}	2026-10-08	\N
16466	1557	2	f	\N	\N	2026-09-20 19:35:17.624779+07	21	auto	\N	\N	\N	{}	\N	\N
16467	1557	15	f	\N	\N	2026-09-20 19:35:17.624779+07	22	auto	\N	\N	\N	{}	\N	\N
3571	418	49	f	\N	\N	2026-09-13 11:09:46.136708+07	27	manual	\N	\N	\N	{}	2026-10-09	\N
16468	1557	27	f	\N	\N	2026-09-20 19:35:17.624779+07	23	auto	\N	\N	\N	{}	\N	\N
16469	1557	38	f	\N	\N	2026-09-20 19:35:17.624779+07	24	auto	\N	\N	\N	{}	\N	\N
16470	1557	39	f	\N	\N	2026-09-20 19:35:17.624779+07	25	auto	\N	\N	\N	{}	\N	\N
16471	1557	94	f	\N	\N	2026-09-20 19:35:17.624779+07	29	auto	\N	\N	\N	{}	\N	\N
16472	1557	96	f	\N	\N	2026-09-20 19:35:17.624779+07	30	auto	\N	\N	\N	{}	\N	\N
16473	1557	102	f	\N	\N	2026-09-20 19:35:17.624779+07	28	auto	\N	\N	\N	{}	2026-11-13	\N
16474	1557	99	f	\N	\N	2026-09-20 19:35:17.624779+07	27	auto	\N	\N	\N	{}	2026-11-14	\N
16475	1557	107	f	\N	\N	2026-09-20 19:35:17.624779+07	28	auto	\N	\N	\N	{}	2026-11-14	\N
16476	1557	95	f	\N	\N	2026-09-20 19:35:17.624779+07	27	auto	\N	\N	\N	{}	2026-11-15	\N
16477	1557	109	f	\N	\N	2026-09-20 19:35:17.624779+07	28	auto	\N	\N	\N	{}	2026-11-15	\N
16478	1557	75	f	\N	\N	2026-09-20 19:35:17.624779+07	27	auto	\N	\N	\N	{}	2026-11-16	\N
16479	1557	77	f	\N	\N	2026-09-20 19:35:17.624779+07	28	auto	\N	\N	\N	{}	2026-11-16	\N
16480	1557	51	f	\N	\N	2026-09-20 19:35:17.624779+07	27	auto	\N	\N	\N	{}	2026-11-17	\N
16483	1558	108	f	\N	\N	2026-09-20 19:35:17.885166+07	20	auto	\N	\N	\N	{}	\N	\N
16484	1558	6	f	\N	\N	2026-09-20 19:35:17.885166+07	21	auto	\N	\N	\N	{}	\N	\N
16485	1558	7	f	\N	\N	2026-09-20 19:35:17.885166+07	22	auto	\N	\N	\N	{}	\N	\N
16486	1558	14	f	\N	\N	2026-09-20 19:35:17.885166+07	23	auto	\N	\N	\N	{}	\N	\N
16487	1558	19	f	\N	\N	2026-09-20 19:35:17.885166+07	24	auto	\N	\N	\N	{}	\N	\N
16488	1558	18	f	\N	\N	2026-09-20 19:35:17.885166+07	25	auto	\N	\N	\N	{}	\N	\N
16489	1558	105	f	\N	\N	2026-09-20 19:35:17.885166+07	29	auto	\N	\N	\N	{}	\N	\N
16490	1558	101	f	\N	\N	2026-09-20 19:35:17.885166+07	30	auto	\N	\N	\N	{}	\N	\N
16491	1558	103	f	\N	\N	2026-09-20 19:35:17.885166+07	28	auto	\N	\N	\N	{}	2026-11-17	\N
16492	1558	106	f	\N	\N	2026-09-20 19:35:17.885166+07	27	auto	\N	\N	\N	{}	2026-11-18	\N
16493	1558	93	f	\N	\N	2026-09-20 19:35:17.885166+07	28	auto	\N	\N	\N	{}	2026-11-18	\N
16494	1558	8	f	\N	\N	2026-09-20 19:35:17.885166+07	27	auto	\N	\N	\N	{}	2026-11-19	\N
16495	1558	26	f	\N	\N	2026-09-20 19:35:17.885166+07	28	auto	\N	\N	\N	{}	2026-11-19	\N
16496	1558	91	f	\N	\N	2026-09-20 19:35:17.885166+07	27	auto	\N	\N	\N	{}	2026-11-20	\N
16499	1559	102	f	\N	\N	2026-09-20 19:35:18.10492+07	20	auto	\N	\N	\N	{}	\N	\N
16500	1559	2	f	\N	\N	2026-09-20 19:35:18.10492+07	21	auto	\N	\N	\N	{}	\N	\N
16501	1559	15	f	\N	\N	2026-09-20 19:35:18.10492+07	22	auto	\N	\N	\N	{}	\N	\N
16502	1559	27	f	\N	\N	2026-09-20 19:35:18.10492+07	23	auto	\N	\N	\N	{}	\N	\N
16503	1559	38	f	\N	\N	2026-09-20 19:35:18.10492+07	24	auto	\N	\N	\N	{}	\N	\N
16504	1559	39	f	\N	\N	2026-09-20 19:35:18.10492+07	25	auto	\N	\N	\N	{}	\N	\N
16505	1559	96	f	\N	\N	2026-09-20 19:35:18.10492+07	29	auto	\N	\N	\N	{}	\N	\N
16506	1559	107	f	\N	\N	2026-09-20 19:35:18.10492+07	30	auto	\N	\N	\N	{}	\N	\N
16507	1559	97	f	\N	\N	2026-09-20 19:35:18.10492+07	28	auto	\N	\N	\N	{}	2026-11-20	\N
16508	1559	99	f	\N	\N	2026-09-20 19:35:18.10492+07	27	auto	\N	\N	\N	{}	2026-11-21	\N
16509	1559	109	f	\N	\N	2026-09-20 19:35:18.10492+07	28	auto	\N	\N	\N	{}	2026-11-21	\N
16510	1559	95	f	\N	\N	2026-09-20 19:35:18.10492+07	27	auto	\N	\N	\N	{}	2026-11-22	\N
16511	1559	105	f	\N	\N	2026-09-20 19:35:18.10492+07	28	auto	\N	\N	\N	{}	2026-11-22	\N
16512	1559	83	f	\N	\N	2026-09-20 19:35:18.10492+07	27	auto	\N	\N	\N	{}	2026-11-23	\N
4426	450	9	f	\N	\N	2026-09-19 14:46:58.745138+07	7	auto	\N	\N	\N	{}	\N	\N
4427	450	42	f	\N	\N	2026-09-19 14:46:58.745138+07	11	auto	\N	\N	\N	{}	\N	\N
16513	1559	61	f	\N	\N	2026-09-20 19:35:18.10492+07	28	auto	\N	\N	\N	{}	2026-11-23	\N
16514	1559	94	f	\N	\N	2026-09-20 19:35:18.10492+07	27	auto	\N	\N	\N	{}	2026-11-24	\N
16517	1560	108	f	\N	\N	2026-09-20 19:35:18.366559+07	20	auto	\N	\N	\N	{}	\N	\N
16518	1560	19	f	\N	\N	2026-09-20 19:35:18.366559+07	21	auto	\N	\N	\N	{}	\N	\N
16519	1560	6	f	\N	\N	2026-09-20 19:35:18.366559+07	22	auto	\N	\N	\N	{}	\N	\N
16520	1560	7	f	\N	\N	2026-09-20 19:35:18.366559+07	23	auto	\N	\N	\N	{}	\N	\N
16521	1560	14	f	\N	\N	2026-09-20 19:35:18.366559+07	24	auto	\N	\N	\N	{}	\N	\N
16522	1560	18	f	\N	\N	2026-09-20 19:35:18.366559+07	25	auto	\N	\N	\N	{}	\N	\N
16523	1560	93	f	\N	\N	2026-09-20 19:35:18.366559+07	29	auto	\N	\N	\N	{}	\N	\N
16524	1560	106	f	\N	\N	2026-09-20 19:35:18.366559+07	30	auto	\N	\N	\N	{}	\N	\N
16525	1560	32	f	\N	\N	2026-09-20 19:35:18.366559+07	28	auto	\N	\N	\N	{}	2026-11-24	\N
3376	388	138	f	\N	\N	2026-09-07 15:37:30.739624+07	1	manual	\N	\N	\N	{}	\N	\N
16526	1560	103	f	\N	\N	2026-09-20 19:35:18.366559+07	27	auto	\N	\N	\N	{}	2026-11-25	\N
16527	1560	26	f	\N	\N	2026-09-20 19:35:18.366559+07	28	auto	\N	\N	\N	{}	2026-11-25	\N
16528	1560	96	f	\N	\N	2026-09-20 19:35:18.366559+07	27	auto	\N	\N	\N	{}	2026-11-26	\N
16529	1560	102	f	\N	\N	2026-09-20 19:35:18.366559+07	28	auto	\N	\N	\N	{}	2026-11-26	\N
16530	1560	101	f	\N	\N	2026-09-20 19:35:18.366559+07	27	auto	\N	\N	\N	{}	2026-11-27	\N
16533	1561	107	f	\N	\N	2026-09-20 19:35:18.599014+07	20	auto	\N	\N	\N	{}	\N	\N
2815	345	117	f	\N	\N	2026-09-07 14:47:53.772172+07	18	manual	\N	\N	\N	{}	\N	\N
2816	345	118	f	\N	\N	2026-09-07 14:47:53.772172+07	19	manual	\N	\N	\N	{}	\N	\N
2817	345	94	f	\N	\N	2026-09-07 14:47:53.772172+07	20	manual	\N	\N	\N	{}	\N	\N
16534	1561	2	f	\N	\N	2026-09-20 19:35:18.599014+07	21	auto	\N	\N	\N	{}	\N	\N
16535	1561	15	f	\N	\N	2026-09-20 19:35:18.599014+07	22	auto	\N	\N	\N	{}	\N	\N
16536	1561	27	f	\N	\N	2026-09-20 19:35:18.599014+07	23	auto	\N	\N	\N	{}	\N	\N
16537	1561	38	f	\N	\N	2026-09-20 19:35:18.599014+07	24	auto	\N	\N	\N	{}	\N	\N
16538	1561	39	f	\N	\N	2026-09-20 19:35:18.599014+07	25	auto	\N	\N	\N	{}	\N	\N
16539	1561	109	f	\N	\N	2026-09-20 19:35:18.599014+07	29	auto	\N	\N	\N	{}	\N	\N
16540	1561	8	f	\N	\N	2026-09-20 19:35:18.599014+07	30	auto	\N	\N	\N	{}	\N	\N
2818	345	5	f	\N	\N	2026-09-07 14:47:53.772172+07	21	manual	\N	\N	\N	{}	\N	\N
2819	345	39	f	\N	\N	2026-09-07 14:47:53.772172+07	22	manual	\N	\N	\N	{}	\N	\N
2820	345	16	f	\N	\N	2026-09-07 14:47:53.772172+07	23	manual	\N	\N	\N	{}	\N	\N
2821	345	17	f	\N	\N	2026-09-07 14:47:53.772172+07	24	manual	\N	\N	\N	{}	\N	\N
2822	345	18	f	\N	\N	2026-09-07 14:47:53.772172+07	25	manual	\N	\N	\N	{}	\N	\N
2857	350	101	f	\N	\N	2026-09-07 14:47:53.804359+07	20	manual	\N	\N	\N	{}	\N	\N
2858	350	27	f	\N	\N	2026-09-07 14:47:53.804359+07	21	manual	\N	\N	\N	{}	\N	\N
2859	350	39	f	\N	\N	2026-09-07 14:47:53.804359+07	22	manual	\N	\N	\N	{}	\N	\N
2860	350	2	f	\N	\N	2026-09-07 14:47:53.804359+07	23	manual	\N	\N	\N	{}	\N	\N
2861	350	38	f	\N	\N	2026-09-07 14:47:53.804359+07	24	manual	\N	\N	\N	{}	\N	\N
2862	350	4	f	\N	\N	2026-09-07 14:47:53.804359+07	25	manual	\N	\N	\N	{}	\N	\N
16541	1561	95	f	\N	\N	2026-09-20 19:35:18.599014+07	28	auto	\N	\N	\N	{}	2026-11-27	\N
16542	1561	87	f	\N	\N	2026-09-20 19:35:18.599014+07	27	auto	\N	\N	\N	{}	2026-11-28	\N
16543	1561	89	f	\N	\N	2026-09-20 19:35:18.599014+07	28	auto	\N	\N	\N	{}	2026-11-28	\N
16544	1561	97	f	\N	\N	2026-09-20 19:35:18.599014+07	27	auto	\N	\N	\N	{}	2026-11-29	\N
16545	1561	99	f	\N	\N	2026-09-20 19:35:18.599014+07	28	auto	\N	\N	\N	{}	2026-11-29	\N
16546	1561	77	f	\N	\N	2026-09-20 19:35:18.599014+07	27	auto	\N	\N	\N	{}	2026-11-30	\N
16547	1561	63	f	\N	\N	2026-09-20 19:35:18.599014+07	28	auto	\N	\N	\N	{}	2026-11-30	\N
16548	1561	85	f	\N	\N	2026-09-20 19:35:18.599014+07	27	auto	\N	\N	\N	{}	2026-12-01	\N
2823	346	119	f	\N	\N	2026-09-07 14:47:53.779781+07	18	manual	\N	\N	\N	{}	\N	\N
2824	346	121	f	\N	\N	2026-09-07 14:47:53.779781+07	19	manual	\N	\N	\N	{}	\N	\N
2825	346	95	f	\N	\N	2026-09-07 14:47:53.779781+07	20	manual	\N	\N	\N	{}	\N	\N
2826	346	14	f	\N	\N	2026-09-07 14:47:53.779781+07	21	manual	\N	\N	\N	{}	\N	\N
2827	346	2	f	\N	\N	2026-09-07 14:47:53.779781+07	22	manual	\N	\N	\N	{}	\N	\N
2828	346	12	f	\N	\N	2026-09-07 14:47:53.779781+07	23	manual	\N	\N	\N	{}	\N	\N
2829	346	15	f	\N	\N	2026-09-07 14:47:53.779781+07	24	manual	\N	\N	\N	{}	\N	\N
2830	346	24	f	\N	\N	2026-09-07 14:47:53.779781+07	25	manual	\N	\N	\N	{}	\N	\N
3377	378	148	f	\N	\N	2026-09-07 16:00:56.101443+07	6	manual	\N	\N	\N	{}	\N	\N
16551	1562	8	f	\N	\N	2026-09-20 19:39:19.242301+07	20	auto	\N	\N	\N	{}	\N	\N
16552	1562	16	f	\N	\N	2026-09-20 19:39:19.242301+07	21	auto	\N	\N	\N	{}	\N	\N
16553	1562	18	f	\N	\N	2026-09-20 19:39:19.242301+07	22	auto	\N	\N	\N	{}	\N	\N
16554	1562	24	f	\N	\N	2026-09-20 19:39:19.242301+07	23	auto	\N	\N	\N	{}	\N	\N
16555	1562	26	f	\N	\N	2026-09-20 19:39:19.242301+07	24	auto	\N	\N	\N	{}	\N	\N
16556	1562	25	f	\N	\N	2026-09-20 19:39:19.242301+07	25	auto	\N	\N	\N	{}	\N	\N
16557	1562	32	f	\N	\N	2026-09-20 19:39:19.242301+07	29	auto	\N	\N	\N	{}	\N	\N
16558	1562	6	f	\N	\N	2026-09-20 19:39:19.242301+07	30	auto	\N	\N	\N	{}	\N	\N
16559	1562	72	f	\N	\N	2026-09-20 19:39:19.242301+07	28	auto	\N	\N	\N	{}	2026-10-02	\N
16560	1562	73	f	\N	\N	2026-09-20 19:39:19.242301+07	27	auto	\N	\N	\N	{}	2026-10-03	\N
16561	1562	99	f	\N	\N	2026-09-20 19:39:19.242301+07	28	auto	\N	\N	\N	{}	2026-10-03	\N
16562	1562	108	f	\N	\N	2026-09-20 19:39:19.242301+07	27	auto	\N	\N	\N	{}	2026-10-04	\N
16563	1562	17	f	\N	\N	2026-09-20 19:39:19.242301+07	28	auto	\N	\N	\N	{}	2026-10-04	\N
16564	1562	61	f	\N	\N	2026-09-20 19:39:19.242301+07	27	auto	\N	\N	\N	{}	2026-10-05	\N
16565	1562	65	f	\N	\N	2026-09-20 19:39:19.242301+07	28	auto	\N	\N	\N	{}	2026-10-05	\N
16566	1562	7	f	\N	\N	2026-09-20 19:39:19.242301+07	27	auto	\N	\N	\N	{}	2026-10-06	\N
16569	1563	105	f	\N	\N	2026-09-20 19:39:19.609032+07	20	auto	\N	\N	\N	{}	\N	\N
16570	1563	38	f	\N	\N	2026-09-20 19:39:19.609032+07	21	auto	\N	\N	\N	{}	\N	\N
16571	1563	39	f	\N	\N	2026-09-20 19:39:19.609032+07	22	auto	\N	\N	\N	{}	\N	\N
16572	1563	27	f	\N	\N	2026-09-20 19:39:19.609032+07	23	auto	\N	\N	\N	{}	\N	\N
16573	1563	4	f	\N	\N	2026-09-20 19:39:19.609032+07	24	auto	\N	\N	\N	{}	\N	\N
16574	1563	37	f	\N	\N	2026-09-20 19:39:19.609032+07	25	auto	\N	\N	\N	{}	\N	\N
16575	1563	12	f	\N	\N	2026-09-20 19:39:19.609032+07	29	auto	\N	\N	\N	{}	\N	\N
16576	1563	47	f	\N	\N	2026-09-20 19:39:19.609032+07	30	auto	\N	\N	\N	{}	\N	\N
16577	1563	69	f	\N	\N	2026-09-20 19:39:19.609032+07	28	auto	\N	\N	\N	{}	2026-10-09	\N
16578	1563	64	f	\N	\N	2026-09-20 19:39:19.609032+07	27	auto	\N	\N	\N	{}	2026-10-10	\N
16579	1563	66	f	\N	\N	2026-09-20 19:39:19.609032+07	28	auto	\N	\N	\N	{}	2026-10-10	\N
16580	1563	83	f	\N	\N	2026-09-20 19:39:19.609032+07	27	auto	\N	\N	\N	{}	2026-10-11	\N
16581	1563	48	f	\N	\N	2026-09-20 19:39:19.609032+07	28	auto	\N	\N	\N	{}	2026-10-11	\N
16582	1563	77	f	\N	\N	2026-09-20 19:39:19.609032+07	27	auto	\N	\N	\N	{}	2026-10-12	\N
16583	1563	67	f	\N	\N	2026-09-20 19:39:19.609032+07	28	auto	\N	\N	\N	{}	2026-10-12	\N
16584	1563	94	f	\N	\N	2026-09-20 19:39:19.609032+07	27	auto	\N	\N	\N	{}	2026-10-13	\N
16587	1564	93	f	\N	\N	2026-09-20 19:39:19.854092+07	20	auto	\N	\N	\N	{}	\N	\N
16588	1564	5	f	\N	\N	2026-09-20 19:39:19.854092+07	21	auto	\N	\N	\N	{}	\N	\N
16589	1564	19	f	\N	\N	2026-09-20 19:39:19.854092+07	22	auto	\N	\N	\N	{}	\N	\N
16590	1564	25	f	\N	\N	2026-09-20 19:39:19.854092+07	23	auto	\N	\N	\N	{}	\N	\N
16591	1564	24	f	\N	\N	2026-09-20 19:39:19.854092+07	24	auto	\N	\N	\N	{}	\N	\N
16592	1564	17	f	\N	\N	2026-09-20 19:39:19.854092+07	25	auto	\N	\N	\N	{}	\N	\N
16593	1564	51	f	\N	\N	2026-09-20 19:39:19.854092+07	29	auto	\N	\N	\N	{}	\N	\N
16594	1564	53	f	\N	\N	2026-09-20 19:39:19.854092+07	30	auto	\N	\N	\N	{}	\N	\N
16595	1564	52	f	\N	\N	2026-09-20 19:39:19.854092+07	28	auto	\N	\N	\N	{}	2026-10-13	\N
16596	1564	60	f	\N	\N	2026-09-20 19:39:19.854092+07	27	auto	\N	\N	\N	{}	2026-10-14	\N
16597	1564	58	f	\N	\N	2026-09-20 19:39:19.854092+07	28	auto	\N	\N	\N	{}	2026-10-14	\N
16598	1564	70	f	\N	\N	2026-09-20 19:39:19.854092+07	27	auto	\N	\N	\N	{}	2026-10-15	\N
16599	1564	71	f	\N	\N	2026-09-20 19:39:19.854092+07	28	auto	\N	\N	\N	{}	2026-10-15	\N
16600	1564	76	f	\N	\N	2026-09-20 19:39:19.854092+07	27	auto	\N	\N	\N	{}	2026-10-16	\N
16603	1565	32	f	\N	\N	2026-09-20 19:39:20.054591+07	20	auto	\N	\N	\N	{}	\N	\N
16604	1565	14	f	\N	\N	2026-09-20 19:39:20.054591+07	21	auto	\N	\N	\N	{}	\N	\N
16605	1565	29	f	\N	\N	2026-09-20 19:39:20.054591+07	22	auto	\N	\N	\N	{}	\N	\N
16606	1565	36	f	\N	\N	2026-09-20 19:39:20.054591+07	23	auto	\N	\N	\N	{}	\N	\N
16607	1565	28	f	\N	\N	2026-09-20 19:39:20.054591+07	24	auto	\N	\N	\N	{}	\N	\N
16608	1565	6	f	\N	\N	2026-09-20 19:39:20.054591+07	25	auto	\N	\N	\N	{}	\N	\N
16609	1565	43	f	\N	\N	2026-09-20 19:39:20.054591+07	29	auto	\N	\N	\N	{}	\N	\N
16610	1565	45	f	\N	\N	2026-09-20 19:39:20.054591+07	30	auto	\N	\N	\N	{}	\N	\N
16611	1565	46	f	\N	\N	2026-09-20 19:39:20.054591+07	28	auto	\N	\N	\N	{}	2026-10-16	\N
16612	1565	42	f	\N	\N	2026-09-20 19:39:20.054591+07	27	auto	\N	\N	\N	{}	2026-10-17	\N
16613	1565	55	f	\N	\N	2026-09-20 19:39:20.054591+07	28	auto	\N	\N	\N	{}	2026-10-17	\N
16614	1565	41	f	\N	\N	2026-09-20 19:39:20.054591+07	27	auto	\N	\N	\N	{}	2026-10-18	\N
16615	1565	89	f	\N	\N	2026-09-20 19:39:20.054591+07	28	auto	\N	\N	\N	{}	2026-10-18	\N
16616	1565	87	f	\N	\N	2026-09-20 19:39:20.054591+07	27	auto	\N	\N	\N	{}	2026-10-19	\N
16617	1565	57	f	\N	\N	2026-09-20 19:39:20.054591+07	28	auto	\N	\N	\N	{}	2026-10-19	\N
16618	1565	91	f	\N	\N	2026-09-20 19:39:20.054591+07	27	auto	\N	\N	\N	{}	2026-10-20	\N
16621	1566	107	f	\N	\N	2026-09-20 19:39:20.299202+07	20	auto	\N	\N	\N	{}	\N	\N
16622	1566	7	f	\N	\N	2026-09-20 19:39:20.299202+07	21	auto	\N	\N	\N	{}	\N	\N
16623	1566	16	f	\N	\N	2026-09-20 19:39:20.299202+07	22	auto	\N	\N	\N	{}	\N	\N
16624	1566	37	f	\N	\N	2026-09-20 19:39:20.299202+07	23	auto	\N	\N	\N	{}	\N	\N
16625	1566	18	f	\N	\N	2026-09-20 19:39:20.299202+07	24	auto	\N	\N	\N	{}	\N	\N
16626	1566	26	f	\N	\N	2026-09-20 19:39:20.299202+07	25	auto	\N	\N	\N	{}	\N	\N
16627	1566	72	f	\N	\N	2026-09-20 19:39:20.299202+07	29	auto	\N	\N	\N	{}	\N	\N
16628	1566	73	f	\N	\N	2026-09-20 19:39:20.299202+07	30	auto	\N	\N	\N	{}	\N	\N
16629	1566	61	f	\N	\N	2026-09-20 19:39:20.299202+07	28	auto	\N	\N	\N	{}	2026-10-20	\N
16630	1566	84	f	\N	\N	2026-09-20 19:39:20.299202+07	27	auto	\N	\N	\N	{}	2026-10-21	\N
16631	1566	63	f	\N	\N	2026-09-20 19:39:20.299202+07	28	auto	\N	\N	\N	{}	2026-10-21	\N
16632	1566	81	f	\N	\N	2026-09-20 19:39:20.299202+07	27	auto	\N	\N	\N	{}	2026-10-22	\N
16633	1566	102	f	\N	\N	2026-09-20 19:39:20.299202+07	28	auto	\N	\N	\N	{}	2026-10-22	\N
3378	410	142	f	\N	\N	2026-09-07 17:15:52.35375+07	2	manual	\N	\N	\N	{}	\N	\N
3803	347	89	f	\N	\N	2026-09-13 11:39:43.422909+07	29	manual	\N	\N	\N	{}	\N	\N
3804	347	29	f	\N	\N	2026-09-13 11:39:43.422909+07	30	manual	\N	\N	\N	{}	\N	\N
16634	1566	65	f	\N	\N	2026-09-20 19:39:20.299202+07	27	auto	\N	\N	\N	{}	2026-10-23	\N
16637	1567	109	f	\N	\N	2026-09-20 19:39:20.498088+07	20	auto	\N	\N	\N	{}	\N	\N
16638	1567	25	f	\N	\N	2026-09-20 19:39:20.498088+07	21	auto	\N	\N	\N	{}	\N	\N
16639	1567	24	f	\N	\N	2026-09-20 19:39:20.498088+07	22	auto	\N	\N	\N	{}	\N	\N
16640	1567	15	f	\N	\N	2026-09-20 19:39:20.498088+07	23	auto	\N	\N	\N	{}	\N	\N
16641	1567	2	f	\N	\N	2026-09-20 19:39:20.498088+07	24	auto	\N	\N	\N	{}	\N	\N
16642	1567	36	f	\N	\N	2026-09-20 19:39:20.498088+07	25	auto	\N	\N	\N	{}	\N	\N
16643	1567	82	f	\N	\N	2026-09-20 19:39:20.498088+07	29	auto	\N	\N	\N	{}	\N	\N
16644	1567	78	f	\N	\N	2026-09-20 19:39:20.498088+07	30	auto	\N	\N	\N	{}	\N	\N
16645	1567	95	f	\N	\N	2026-09-20 19:39:20.498088+07	28	auto	\N	\N	\N	{}	2026-10-23	\N
16646	1567	8	f	\N	\N	2026-09-20 19:39:20.498088+07	27	auto	\N	\N	\N	{}	2026-10-24	\N
16647	1567	12	f	\N	\N	2026-09-20 19:39:20.498088+07	28	auto	\N	\N	\N	{}	2026-10-24	\N
16648	1567	49	f	\N	\N	2026-09-20 19:39:20.498088+07	27	auto	\N	\N	\N	{}	2026-10-25	\N
16649	1567	47	f	\N	\N	2026-09-20 19:39:20.498088+07	28	auto	\N	\N	\N	{}	2026-10-25	\N
16650	1567	75	f	\N	\N	2026-09-20 19:39:20.498088+07	27	auto	\N	\N	\N	{}	2026-10-26	\N
16651	1567	48	f	\N	\N	2026-09-20 19:39:20.498088+07	28	auto	\N	\N	\N	{}	2026-10-26	\N
16652	1567	106	f	\N	\N	2026-09-20 19:39:20.498088+07	27	auto	\N	\N	\N	{}	2026-10-27	\N
16655	1568	99	f	\N	\N	2026-09-20 19:39:20.738254+07	20	auto	\N	\N	\N	{}	\N	\N
16656	1568	19	f	\N	\N	2026-09-20 19:39:20.738254+07	21	auto	\N	\N	\N	{}	\N	\N
16657	1568	69	f	\N	\N	2026-09-20 19:39:20.738254+07	29	auto	\N	\N	\N	{}	\N	\N
16658	1568	64	f	\N	\N	2026-09-20 19:39:20.738254+07	30	auto	\N	\N	\N	{}	\N	\N
16659	1568	66	f	\N	\N	2026-09-20 19:39:20.738254+07	28	auto	\N	\N	\N	{}	2026-10-27	\N
16660	1568	67	f	\N	\N	2026-09-20 19:39:20.738254+07	27	auto	\N	\N	\N	{}	2026-10-28	\N
16661	1568	77	f	\N	\N	2026-09-20 19:39:20.738254+07	28	auto	\N	\N	\N	{}	2026-10-28	\N
16662	1568	52	f	\N	\N	2026-09-20 19:39:20.738254+07	27	auto	\N	\N	\N	{}	2026-10-29	\N
16663	1568	51	f	\N	\N	2026-09-20 19:39:20.738254+07	28	auto	\N	\N	\N	{}	2026-10-29	\N
16664	1568	53	f	\N	\N	2026-09-20 19:39:20.738254+07	27	auto	\N	\N	\N	{}	2026-10-30	\N
3805	364	41	f	\N	\N	2026-09-13 11:40:21.242456+07	11	manual	\N	\N	\N	{}	\N	\N
2972	360	123	f	\N	\N	2026-09-07 14:47:53.933026+07	7	auto	\N	\N	\N	{}	\N	\N
2973	360	91	f	\N	\N	2026-09-07 14:47:53.933026+07	13	auto	\N	\N	\N	{}	\N	\N
2974	360	70	f	\N	\N	2026-09-07 14:47:53.933026+07	12	auto	\N	\N	\N	{}	\N	\N
2975	360	53	f	\N	\N	2026-09-07 14:47:53.933026+07	16	auto	\N	\N	\N	{}	\N	\N
2976	360	51	f	\N	\N	2026-09-07 14:47:53.933026+07	17	auto	\N	\N	\N	{}	\N	\N
2977	360	58	f	\N	\N	2026-09-07 14:47:53.933026+07	14	auto	\N	\N	\N	{}	\N	\N
2978	360	52	f	\N	\N	2026-09-07 14:47:53.933026+07	15	auto	\N	\N	\N	{}	\N	\N
2979	360	2	f	\N	\N	2026-09-07 14:47:53.933026+07	8	auto	\N	\N	\N	{}	\N	\N
2980	360	12	f	\N	\N	2026-09-07 14:47:53.933026+07	9	auto	\N	\N	\N	{}	\N	\N
2981	360	15	f	\N	\N	2026-09-07 14:47:53.933026+07	10	auto	\N	\N	\N	{}	\N	\N
2982	360	24	f	\N	\N	2026-09-07 14:47:53.933026+07	11	auto	\N	\N	\N	{}	\N	\N
16667	1569	94	f	\N	\N	2026-09-20 19:39:21.143319+07	20	auto	\N	\N	\N	{}	\N	\N
16668	1569	26	f	\N	\N	2026-09-20 19:39:21.143319+07	21	auto	\N	\N	\N	{}	\N	\N
16669	1569	6	f	\N	\N	2026-09-20 19:39:21.143319+07	22	auto	\N	\N	\N	{}	\N	\N
16670	1569	7	f	\N	\N	2026-09-20 19:39:21.143319+07	23	auto	\N	\N	\N	{}	\N	\N
16671	1569	14	f	\N	\N	2026-09-20 19:39:21.143319+07	24	auto	\N	\N	\N	{}	\N	\N
16672	1569	19	f	\N	\N	2026-09-20 19:39:21.143319+07	25	auto	\N	\N	\N	{}	\N	\N
16673	1569	103	f	\N	\N	2026-09-20 19:39:21.143319+07	29	auto	\N	\N	\N	{}	\N	\N
16674	1569	18	f	\N	\N	2026-09-20 19:39:21.143319+07	30	auto	\N	\N	\N	{}	\N	\N
16675	1569	108	f	\N	\N	2026-09-20 19:39:21.143319+07	28	auto	\N	\N	\N	{}	2026-12-01	\N
16676	1569	75	f	\N	\N	2026-09-20 19:39:21.143319+07	27	auto	\N	\N	\N	{}	2026-12-02	\N
16677	1569	109	f	\N	\N	2026-09-20 19:39:21.143319+07	28	auto	\N	\N	\N	{}	2026-12-02	\N
16678	1569	32	f	\N	\N	2026-09-20 19:39:21.143319+07	27	auto	\N	\N	\N	{}	2026-12-03	\N
16679	1569	105	f	\N	\N	2026-09-20 19:39:21.143319+07	28	auto	\N	\N	\N	{}	2026-12-03	\N
16680	1569	71	f	\N	\N	2026-09-20 19:39:21.143319+07	27	auto	\N	\N	\N	{}	2026-12-04	\N
16683	1570	101	f	\N	\N	2026-09-20 19:39:21.407265+07	20	auto	\N	\N	\N	{}	\N	\N
16684	1570	2	f	\N	\N	2026-09-20 19:39:21.407265+07	21	auto	\N	\N	\N	{}	\N	\N
16685	1570	15	f	\N	\N	2026-09-20 19:39:21.407265+07	22	auto	\N	\N	\N	{}	\N	\N
16686	1570	27	f	\N	\N	2026-09-20 19:39:21.407265+07	23	auto	\N	\N	\N	{}	\N	\N
16687	1570	38	f	\N	\N	2026-09-20 19:39:21.407265+07	24	auto	\N	\N	\N	{}	\N	\N
16688	1570	39	f	\N	\N	2026-09-20 19:39:21.407265+07	25	auto	\N	\N	\N	{}	\N	\N
2863	351	32	f	\N	\N	2026-09-07 14:47:53.869997+07	6	manual	\N	\N	\N	{}	\N	\N
2864	351	93	f	\N	\N	2026-09-07 14:47:53.869997+07	7	manual	\N	\N	\N	{}	\N	\N
2865	351	28	f	\N	\N	2026-09-07 14:47:53.869997+07	13	manual	\N	\N	\N	{}	\N	\N
2866	351	29	f	\N	\N	2026-09-07 14:47:53.869997+07	12	manual	\N	\N	\N	{}	\N	\N
2867	351	36	f	\N	\N	2026-09-07 14:47:53.869997+07	16	manual	\N	\N	\N	{}	\N	\N
2868	351	41	f	\N	\N	2026-09-07 14:47:53.869997+07	17	manual	\N	\N	\N	{}	\N	\N
2869	351	37	f	\N	\N	2026-09-07 14:47:53.869997+07	14	manual	\N	\N	\N	{}	\N	\N
2870	351	42	f	\N	\N	2026-09-07 14:47:53.869997+07	15	manual	\N	\N	\N	{}	\N	\N
2871	351	19	f	\N	\N	2026-09-07 14:47:53.869997+07	8	manual	\N	\N	\N	{}	\N	\N
2872	351	26	f	\N	\N	2026-09-07 14:47:53.869997+07	9	manual	\N	\N	\N	{}	\N	\N
2873	351	38	f	\N	\N	2026-09-07 14:47:53.869997+07	10	manual	\N	\N	\N	{}	\N	\N
2874	351	4	f	\N	\N	2026-09-07 14:47:53.869997+07	11	manual	\N	\N	\N	{}	\N	\N
3092	370	107	f	\N	\N	2026-09-07 14:47:53.992718+07	7	manual	\N	\N	\N	{}	\N	\N
3093	370	71	f	\N	\N	2026-09-07 14:47:53.992718+07	13	manual	\N	\N	\N	{}	\N	\N
3094	370	76	f	\N	\N	2026-09-07 14:47:53.992718+07	12	manual	\N	\N	\N	{}	\N	\N
3095	370	53	f	\N	\N	2026-09-07 14:47:53.992718+07	16	manual	\N	\N	\N	{}	\N	\N
3096	370	51	f	\N	\N	2026-09-07 14:47:53.992718+07	17	manual	\N	\N	\N	{}	\N	\N
3097	370	42	f	\N	\N	2026-09-07 14:47:53.992718+07	14	manual	\N	\N	\N	{}	\N	\N
3098	370	46	f	\N	\N	2026-09-07 14:47:53.992718+07	15	manual	\N	\N	\N	{}	\N	\N
3099	370	6	f	\N	\N	2026-09-07 14:47:53.992718+07	8	manual	\N	\N	\N	{}	\N	\N
3100	370	28	f	\N	\N	2026-09-07 14:47:53.992718+07	9	manual	\N	\N	\N	{}	\N	\N
3101	370	7	f	\N	\N	2026-09-07 14:47:53.992718+07	10	manual	\N	\N	\N	{}	\N	\N
3102	370	36	f	\N	\N	2026-09-07 14:47:53.992718+07	11	manual	\N	\N	\N	{}	\N	\N
3151	375	35	f	\N	\N	2026-09-07 14:47:54.021402+07	6	manual	\N	\N	\N	{}	\N	\N
3152	375	133	f	\N	\N	2026-09-07 14:47:54.021402+07	7	manual	\N	\N	\N	{}	\N	\N
3153	375	73	f	\N	\N	2026-09-07 14:47:54.021402+07	13	manual	\N	\N	\N	{}	\N	\N
3154	375	72	f	\N	\N	2026-09-07 14:47:54.021402+07	12	manual	\N	\N	\N	{}	\N	\N
3155	375	57	f	\N	\N	2026-09-07 14:47:54.021402+07	16	manual	\N	\N	\N	{}	\N	\N
3156	375	61	f	\N	\N	2026-09-07 14:47:54.021402+07	17	manual	\N	\N	\N	{}	\N	\N
3157	375	58	f	\N	\N	2026-09-07 14:47:54.021402+07	14	manual	\N	\N	\N	{}	\N	\N
3158	375	60	f	\N	\N	2026-09-07 14:47:54.021402+07	15	manual	\N	\N	\N	{}	\N	\N
3159	375	19	f	\N	\N	2026-09-07 14:47:54.021402+07	8	manual	\N	\N	\N	{}	\N	\N
3160	375	25	f	\N	\N	2026-09-07 14:47:54.021402+07	9	manual	\N	\N	\N	{}	\N	\N
3161	375	55	f	\N	\N	2026-09-07 14:47:54.021402+07	10	manual	\N	\N	\N	{}	\N	\N
3162	375	2	f	\N	\N	2026-09-07 14:47:54.021402+07	11	manual	\N	\N	\N	{}	\N	\N
3199	379	137	f	\N	\N	2026-09-07 14:47:54.044988+07	6	manual	\N	\N	\N	{}	\N	\N
3200	379	103	f	\N	\N	2026-09-07 14:47:54.044988+07	7	manual	\N	\N	\N	{}	\N	\N
3201	379	85	f	\N	\N	2026-09-07 14:47:54.044988+07	13	manual	\N	\N	\N	{}	\N	\N
3202	379	90	f	\N	\N	2026-09-07 14:47:54.044988+07	12	manual	\N	\N	\N	{}	\N	\N
3203	379	53	f	\N	\N	2026-09-07 14:47:54.044988+07	16	manual	\N	\N	\N	{}	\N	\N
3204	379	51	f	\N	\N	2026-09-07 14:47:54.044988+07	17	manual	\N	\N	\N	{}	\N	\N
3205	379	58	f	\N	\N	2026-09-07 14:47:54.044988+07	14	manual	\N	\N	\N	{}	\N	\N
3206	379	60	f	\N	\N	2026-09-07 14:47:54.044988+07	15	manual	\N	\N	\N	{}	\N	\N
3207	379	14	f	\N	\N	2026-09-07 14:47:54.044988+07	8	manual	\N	\N	\N	{}	\N	\N
3208	379	5	f	\N	\N	2026-09-07 14:47:54.044988+07	9	manual	\N	\N	\N	{}	\N	\N
3209	379	15	f	\N	\N	2026-09-07 14:47:54.044988+07	10	manual	\N	\N	\N	{}	\N	\N
3210	379	25	f	\N	\N	2026-09-07 14:47:54.044988+07	11	manual	\N	\N	\N	{}	\N	\N
3233	383	117	f	\N	\N	2026-09-07 14:47:54.067084+07	1	manual	\N	\N	\N	{}	\N	\N
3234	383	118	f	\N	\N	2026-09-07 14:47:54.067084+07	2	manual	\N	\N	\N	{}	\N	\N
3235	383	102	f	\N	\N	2026-09-07 14:47:54.067084+07	3	manual	\N	\N	\N	{}	\N	\N
3236	383	63	f	\N	\N	2026-09-07 14:47:54.067084+07	4	manual	\N	\N	\N	{}	\N	\N
3237	383	65	f	\N	\N	2026-09-07 14:47:54.067084+07	5	manual	\N	\N	\N	{}	\N	\N
3259	388	132	f	\N	\N	2026-09-07 14:47:54.093422+07	2	manual	\N	\N	\N	{}	\N	\N
3260	388	133	f	\N	\N	2026-09-07 14:47:54.093422+07	3	manual	\N	\N	\N	{}	\N	\N
3261	388	70	f	\N	\N	2026-09-07 14:47:54.093422+07	4	manual	\N	\N	\N	{}	\N	\N
3283	393	145	f	\N	\N	2026-09-07 14:47:54.11888+07	1	manual	\N	\N	\N	{}	\N	\N
3284	393	133	f	\N	\N	2026-09-07 14:47:54.11888+07	2	manual	\N	\N	\N	{}	\N	\N
3285	393	101	f	\N	\N	2026-09-07 14:47:54.11888+07	3	manual	\N	\N	\N	{}	\N	\N
3286	393	108	f	\N	\N	2026-09-07 14:47:54.11888+07	4	manual	\N	\N	\N	{}	\N	\N
3287	393	77	f	\N	\N	2026-09-07 14:47:54.11888+07	5	manual	\N	\N	\N	{}	\N	\N
3303	397	150	f	\N	\N	2026-09-07 14:47:54.139715+07	1	manual	\N	\N	\N	{}	\N	\N
3304	397	22	f	\N	\N	2026-09-07 14:47:54.139715+07	2	manual	\N	\N	\N	{}	\N	\N
3305	397	8	f	\N	\N	2026-09-07 14:47:54.139715+07	3	manual	\N	\N	\N	{}	\N	\N
3306	397	78	f	\N	\N	2026-09-07 14:47:54.139715+07	4	manual	\N	\N	\N	{}	\N	\N
16689	1570	8	f	\N	\N	2026-09-20 19:39:21.407265+07	29	auto	\N	\N	\N	{}	\N	\N
16690	1570	106	f	\N	\N	2026-09-20 19:39:21.407265+07	30	auto	\N	\N	\N	{}	\N	\N
16691	1570	99	f	\N	\N	2026-09-20 19:39:21.407265+07	28	auto	\N	\N	\N	{}	2026-12-04	\N
16692	1570	93	f	\N	\N	2026-09-20 19:39:21.407265+07	27	auto	\N	\N	\N	{}	2026-12-05	\N
16693	1570	97	f	\N	\N	2026-09-20 19:39:21.407265+07	28	auto	\N	\N	\N	{}	2026-12-05	\N
16694	1570	96	f	\N	\N	2026-09-20 19:39:21.407265+07	27	auto	\N	\N	\N	{}	2026-12-06	\N
16695	1570	103	f	\N	\N	2026-09-20 19:39:21.407265+07	28	auto	\N	\N	\N	{}	2026-12-06	\N
16696	1570	36	f	\N	\N	2026-09-20 19:39:21.407265+07	27	auto	\N	\N	\N	{}	2026-12-07	\N
16697	1570	49	f	\N	\N	2026-09-20 19:39:21.407265+07	28	auto	\N	\N	\N	{}	2026-12-07	\N
16698	1570	69	f	\N	\N	2026-09-20 19:39:21.407265+07	27	auto	\N	\N	\N	{}	2026-12-08	\N
16701	1571	102	f	\N	\N	2026-09-20 19:39:21.726515+07	20	auto	\N	\N	\N	{}	\N	\N
16702	1571	26	f	\N	\N	2026-09-20 19:39:21.726515+07	21	auto	\N	\N	\N	{}	\N	\N
16703	1571	18	f	\N	\N	2026-09-20 19:39:21.726515+07	22	auto	\N	\N	\N	{}	\N	\N
16704	1571	6	f	\N	\N	2026-09-20 19:39:21.726515+07	23	auto	\N	\N	\N	{}	\N	\N
2875	352	94	f	\N	\N	2026-09-07 14:47:53.879399+07	6	manual	\N	\N	\N	{}	\N	\N
2876	352	95	f	\N	\N	2026-09-07 14:47:53.879399+07	7	manual	\N	\N	\N	{}	\N	\N
2877	352	71	f	\N	\N	2026-09-07 14:47:53.879399+07	13	manual	\N	\N	\N	{}	\N	\N
2878	352	70	f	\N	\N	2026-09-07 14:47:53.879399+07	12	manual	\N	\N	\N	{}	\N	\N
2879	352	43	f	\N	\N	2026-09-07 14:47:53.879399+07	16	manual	\N	\N	\N	{}	\N	\N
2880	352	45	f	\N	\N	2026-09-07 14:47:53.879399+07	17	manual	\N	\N	\N	{}	\N	\N
2881	352	46	f	\N	\N	2026-09-07 14:47:53.879399+07	14	manual	\N	\N	\N	{}	\N	\N
2882	352	48	f	\N	\N	2026-09-07 14:47:53.879399+07	15	manual	\N	\N	\N	{}	\N	\N
2883	352	54	f	\N	\N	2026-09-07 14:47:53.879399+07	8	manual	\N	\N	\N	{}	\N	\N
2884	352	16	f	\N	\N	2026-09-07 14:47:53.879399+07	9	manual	\N	\N	\N	{}	\N	\N
2885	352	55	f	\N	\N	2026-09-07 14:47:53.879399+07	10	manual	\N	\N	\N	{}	\N	\N
2886	352	17	f	\N	\N	2026-09-07 14:47:53.879399+07	11	manual	\N	\N	\N	{}	\N	\N
2935	357	107	f	\N	\N	2026-09-07 14:47:53.914829+07	6	manual	\N	\N	\N	{}	\N	\N
2936	357	108	f	\N	\N	2026-09-07 14:47:53.914829+07	7	manual	\N	\N	\N	{}	\N	\N
2937	357	85	f	\N	\N	2026-09-07 14:47:53.914829+07	13	manual	\N	\N	\N	{}	\N	\N
2938	357	88	f	\N	\N	2026-09-07 14:47:53.914829+07	12	manual	\N	\N	\N	{}	\N	\N
2939	357	67	f	\N	\N	2026-09-07 14:47:53.914829+07	16	manual	\N	\N	\N	{}	\N	\N
2940	357	69	f	\N	\N	2026-09-07 14:47:53.914829+07	17	manual	\N	\N	\N	{}	\N	\N
2941	357	58	f	\N	\N	2026-09-07 14:47:53.914829+07	14	manual	\N	\N	\N	{}	\N	\N
2942	357	52	f	\N	\N	2026-09-07 14:47:53.914829+07	15	manual	\N	\N	\N	{}	\N	\N
2943	357	54	f	\N	\N	2026-09-07 14:47:53.914829+07	8	manual	\N	\N	\N	{}	\N	\N
2944	357	16	f	\N	\N	2026-09-07 14:47:53.914829+07	9	manual	\N	\N	\N	{}	\N	\N
2945	357	55	f	\N	\N	2026-09-07 14:47:53.914829+07	10	manual	\N	\N	\N	{}	\N	\N
2946	357	17	f	\N	\N	2026-09-07 14:47:53.914829+07	11	manual	\N	\N	\N	{}	\N	\N
2983	361	124	f	\N	\N	2026-09-07 14:47:53.939142+07	6	manual	\N	\N	\N	{}	\N	\N
2984	361	125	f	\N	\N	2026-09-07 14:47:53.939142+07	7	manual	\N	\N	\N	{}	\N	\N
2985	361	71	f	\N	\N	2026-09-07 14:47:53.939142+07	13	manual	\N	\N	\N	{}	\N	\N
2986	361	72	f	\N	\N	2026-09-07 14:47:53.939142+07	12	manual	\N	\N	\N	{}	\N	\N
2987	361	67	f	\N	\N	2026-09-07 14:47:53.939142+07	16	manual	\N	\N	\N	{}	\N	\N
2988	361	69	f	\N	\N	2026-09-07 14:47:53.939142+07	17	manual	\N	\N	\N	{}	\N	\N
2989	361	60	f	\N	\N	2026-09-07 14:47:53.939142+07	14	manual	\N	\N	\N	{}	\N	\N
2990	361	64	f	\N	\N	2026-09-07 14:47:53.939142+07	15	manual	\N	\N	\N	{}	\N	\N
2991	361	19	f	\N	\N	2026-09-07 14:47:53.939142+07	8	manual	\N	\N	\N	{}	\N	\N
2992	361	25	f	\N	\N	2026-09-07 14:47:53.939142+07	9	manual	\N	\N	\N	{}	\N	\N
2993	361	26	f	\N	\N	2026-09-07 14:47:53.939142+07	10	manual	\N	\N	\N	{}	\N	\N
2994	361	37	f	\N	\N	2026-09-07 14:47:53.939142+07	11	manual	\N	\N	\N	{}	\N	\N
3103	371	143	f	\N	\N	2026-09-07 14:47:53.998363+07	6	manual	\N	\N	\N	{}	\N	\N
3104	371	108	f	\N	\N	2026-09-07 14:47:53.998363+07	7	manual	\N	\N	\N	{}	\N	\N
3105	371	85	f	\N	\N	2026-09-07 14:47:53.998363+07	13	manual	\N	\N	\N	{}	\N	\N
3106	371	78	f	\N	\N	2026-09-07 14:47:53.998363+07	12	manual	\N	\N	\N	{}	\N	\N
3107	371	57	f	\N	\N	2026-09-07 14:47:53.998363+07	16	manual	\N	\N	\N	{}	\N	\N
3108	371	61	f	\N	\N	2026-09-07 14:47:53.998363+07	17	manual	\N	\N	\N	{}	\N	\N
3109	371	48	f	\N	\N	2026-09-07 14:47:53.998363+07	14	manual	\N	\N	\N	{}	\N	\N
3110	371	52	f	\N	\N	2026-09-07 14:47:53.998363+07	15	manual	\N	\N	\N	{}	\N	\N
3111	371	18	f	\N	\N	2026-09-07 14:47:53.998363+07	8	manual	\N	\N	\N	{}	\N	\N
3112	371	38	f	\N	\N	2026-09-07 14:47:53.998363+07	9	manual	\N	\N	\N	{}	\N	\N
3113	371	16	f	\N	\N	2026-09-07 14:47:53.998363+07	10	manual	\N	\N	\N	{}	\N	\N
3114	371	41	f	\N	\N	2026-09-07 14:47:53.998363+07	11	manual	\N	\N	\N	{}	\N	\N
3188	378	102	f	\N	\N	2026-09-07 14:47:54.039329+07	7	manual	\N	\N	\N	{}	\N	\N
3189	378	83	f	\N	\N	2026-09-07 14:47:54.039329+07	13	manual	\N	\N	\N	{}	\N	\N
3190	378	88	f	\N	\N	2026-09-07 14:47:54.039329+07	12	manual	\N	\N	\N	{}	\N	\N
3191	378	47	f	\N	\N	2026-09-07 14:47:54.039329+07	16	manual	\N	\N	\N	{}	\N	\N
3192	378	49	f	\N	\N	2026-09-07 14:47:54.039329+07	17	manual	\N	\N	\N	{}	\N	\N
3193	378	48	f	\N	\N	2026-09-07 14:47:54.039329+07	14	manual	\N	\N	\N	{}	\N	\N
3194	378	52	f	\N	\N	2026-09-07 14:47:54.039329+07	15	manual	\N	\N	\N	{}	\N	\N
3195	378	54	f	\N	\N	2026-09-07 14:47:54.039329+07	8	manual	\N	\N	\N	{}	\N	\N
3196	378	37	f	\N	\N	2026-09-07 14:47:54.039329+07	9	manual	\N	\N	\N	{}	\N	\N
3197	378	55	f	\N	\N	2026-09-07 14:47:54.039329+07	10	manual	\N	\N	\N	{}	\N	\N
3198	378	41	f	\N	\N	2026-09-07 14:47:54.039329+07	11	manual	\N	\N	\N	{}	\N	\N
3228	382	114	f	\N	\N	2026-09-07 14:47:54.061865+07	1	manual	\N	\N	\N	{}	\N	\N
3229	382	115	f	\N	\N	2026-09-07 14:47:54.061865+07	2	manual	\N	\N	\N	{}	\N	\N
3230	382	99	f	\N	\N	2026-09-07 14:47:54.061865+07	3	manual	\N	\N	\N	{}	\N	\N
3231	382	60	f	\N	\N	2026-09-07 14:47:54.061865+07	4	manual	\N	\N	\N	{}	\N	\N
3232	382	61	f	\N	\N	2026-09-07 14:47:54.061865+07	5	manual	\N	\N	\N	{}	\N	\N
3253	387	127	f	\N	\N	2026-09-07 14:47:54.088651+07	1	manual	\N	\N	\N	{}	\N	\N
3254	387	129	f	\N	\N	2026-09-07 14:47:54.088651+07	2	manual	\N	\N	\N	{}	\N	\N
3255	387	130	f	\N	\N	2026-09-07 14:47:54.088651+07	3	manual	\N	\N	\N	{}	\N	\N
3256	387	91	f	\N	\N	2026-09-07 14:47:54.088651+07	4	manual	\N	\N	\N	{}	\N	\N
3257	387	39	f	\N	\N	2026-09-07 14:47:54.088651+07	5	manual	\N	\N	\N	{}	\N	\N
3278	392	144	f	\N	\N	2026-09-07 14:47:54.11409+07	1	manual	\N	\N	\N	{}	\N	\N
3279	392	131	f	\N	\N	2026-09-07 14:47:54.11409+07	2	manual	\N	\N	\N	{}	\N	\N
3280	392	95	f	\N	\N	2026-09-07 14:47:54.11409+07	3	manual	\N	\N	\N	{}	\N	\N
3281	392	90	f	\N	\N	2026-09-07 14:47:54.11409+07	4	manual	\N	\N	\N	{}	\N	\N
3282	392	97	f	\N	\N	2026-09-07 14:47:54.11409+07	5	manual	\N	\N	\N	{}	\N	\N
3308	398	147	f	\N	\N	2026-09-07 14:47:54.145247+07	1	manual	\N	\N	\N	{}	\N	\N
3309	398	34	f	\N	\N	2026-09-07 14:47:54.145247+07	2	manual	\N	\N	\N	{}	\N	\N
3310	398	111	f	\N	\N	2026-09-07 14:47:54.145247+07	3	manual	\N	\N	\N	{}	\N	\N
3311	398	84	f	\N	\N	2026-09-07 14:47:54.145247+07	4	manual	\N	\N	\N	{}	\N	\N
3312	398	102	f	\N	\N	2026-09-07 14:47:54.145247+07	5	manual	\N	\N	\N	{}	\N	\N
3353	407	143	f	\N	\N	2026-09-07 14:47:54.192397+07	1	manual	\N	\N	\N	{}	\N	\N
3354	407	127	f	\N	\N	2026-09-07 14:47:54.192397+07	2	manual	\N	\N	\N	{}	\N	\N
3356	407	39	f	\N	\N	2026-09-07 14:47:54.192397+07	4	manual	\N	\N	\N	{}	\N	\N
3357	407	85	f	\N	\N	2026-09-07 14:47:54.192397+07	5	manual	\N	\N	\N	{}	\N	\N
16705	1571	7	f	\N	\N	2026-09-20 19:39:21.726515+07	24	auto	\N	\N	\N	{}	\N	\N
16706	1571	14	f	\N	\N	2026-09-20 19:39:21.726515+07	25	auto	\N	\N	\N	{}	\N	\N
16707	1571	94	f	\N	\N	2026-09-20 19:39:21.726515+07	29	auto	\N	\N	\N	{}	\N	\N
16708	1571	95	f	\N	\N	2026-09-20 19:39:21.726515+07	30	auto	\N	\N	\N	{}	\N	\N
16709	1571	19	f	\N	\N	2026-09-20 19:39:21.726515+07	28	auto	\N	\N	\N	{}	2026-12-08	\N
16710	1571	105	f	\N	\N	2026-09-20 19:39:21.726515+07	27	auto	\N	\N	\N	{}	2026-12-09	\N
16711	1571	107	f	\N	\N	2026-09-20 19:39:21.726515+07	28	auto	\N	\N	\N	{}	2026-12-09	\N
16712	1571	61	f	\N	\N	2026-09-20 19:39:21.726515+07	27	auto	\N	\N	\N	{}	2026-12-10	\N
16713	1571	106	f	\N	\N	2026-09-20 19:39:21.726515+07	28	auto	\N	\N	\N	{}	2026-12-10	\N
16714	1571	53	f	\N	\N	2026-09-20 19:39:21.726515+07	27	auto	\N	\N	\N	{}	2026-12-11	\N
16717	1572	99	f	\N	\N	2026-09-20 19:39:22.000365+07	20	auto	\N	\N	\N	{}	\N	\N
16718	1572	2	f	\N	\N	2026-09-20 19:39:22.000365+07	21	auto	\N	\N	\N	{}	\N	\N
16719	1572	15	f	\N	\N	2026-09-20 19:39:22.000365+07	22	auto	\N	\N	\N	{}	\N	\N
16720	1572	27	f	\N	\N	2026-09-20 19:39:22.000365+07	23	auto	\N	\N	\N	{}	\N	\N
16721	1572	38	f	\N	\N	2026-09-20 19:39:22.000365+07	24	auto	\N	\N	\N	{}	\N	\N
16722	1572	39	f	\N	\N	2026-09-20 19:39:22.000365+07	25	auto	\N	\N	\N	{}	\N	\N
16723	1572	101	f	\N	\N	2026-09-20 19:39:22.000365+07	29	auto	\N	\N	\N	{}	\N	\N
16724	1572	65	f	\N	\N	2026-09-20 19:39:22.000365+07	30	auto	\N	\N	\N	{}	\N	\N
16725	1572	8	f	\N	\N	2026-09-20 19:39:22.000365+07	28	auto	\N	\N	\N	{}	2026-12-11	\N
16726	1572	63	f	\N	\N	2026-09-20 19:39:22.000365+07	27	auto	\N	\N	\N	{}	2026-12-12	\N
16727	1572	85	f	\N	\N	2026-09-20 19:39:22.000365+07	28	auto	\N	\N	\N	{}	2026-12-12	\N
2887	353	96	f	\N	\N	2026-09-07 14:47:53.886234+07	6	manual	\N	\N	\N	{}	\N	\N
2888	353	97	f	\N	\N	2026-09-07 14:47:53.886234+07	7	manual	\N	\N	\N	{}	\N	\N
2889	353	73	f	\N	\N	2026-09-07 14:47:53.886234+07	13	manual	\N	\N	\N	{}	\N	\N
2890	353	72	f	\N	\N	2026-09-07 14:47:53.886234+07	12	manual	\N	\N	\N	{}	\N	\N
2891	353	47	f	\N	\N	2026-09-07 14:47:53.886234+07	16	manual	\N	\N	\N	{}	\N	\N
2892	353	49	f	\N	\N	2026-09-07 14:47:53.886234+07	17	manual	\N	\N	\N	{}	\N	\N
2893	353	58	f	\N	\N	2026-09-07 14:47:53.886234+07	14	manual	\N	\N	\N	{}	\N	\N
2894	353	52	f	\N	\N	2026-09-07 14:47:53.886234+07	15	manual	\N	\N	\N	{}	\N	\N
2895	353	6	f	\N	\N	2026-09-07 14:47:53.886234+07	8	manual	\N	\N	\N	{}	\N	\N
2896	353	36	f	\N	\N	2026-09-07 14:47:53.886234+07	9	manual	\N	\N	\N	{}	\N	\N
2897	353	7	f	\N	\N	2026-09-07 14:47:53.886234+07	10	manual	\N	\N	\N	{}	\N	\N
2898	353	41	f	\N	\N	2026-09-07 14:47:53.886234+07	11	manual	\N	\N	\N	{}	\N	\N
2995	362	126	f	\N	\N	2026-09-07 14:47:53.94488+07	6	manual	\N	\N	\N	{}	\N	\N
2996	362	127	f	\N	\N	2026-09-07 14:47:53.94488+07	7	manual	\N	\N	\N	{}	\N	\N
2997	362	73	f	\N	\N	2026-09-07 14:47:53.94488+07	13	manual	\N	\N	\N	{}	\N	\N
2998	362	76	f	\N	\N	2026-09-07 14:47:53.94488+07	12	manual	\N	\N	\N	{}	\N	\N
2999	362	57	f	\N	\N	2026-09-07 14:47:53.94488+07	16	manual	\N	\N	\N	{}	\N	\N
3000	362	61	f	\N	\N	2026-09-07 14:47:53.94488+07	17	manual	\N	\N	\N	{}	\N	\N
3001	362	42	f	\N	\N	2026-09-07 14:47:53.94488+07	14	manual	\N	\N	\N	{}	\N	\N
3002	362	46	f	\N	\N	2026-09-07 14:47:53.94488+07	15	manual	\N	\N	\N	{}	\N	\N
3003	362	28	f	\N	\N	2026-09-07 14:47:53.94488+07	8	manual	\N	\N	\N	{}	\N	\N
3004	362	2	f	\N	\N	2026-09-07 14:47:53.94488+07	9	manual	\N	\N	\N	{}	\N	\N
3005	362	55	f	\N	\N	2026-09-07 14:47:53.94488+07	10	manual	\N	\N	\N	{}	\N	\N
3006	362	4	f	\N	\N	2026-09-07 14:47:53.94488+07	11	manual	\N	\N	\N	{}	\N	\N
3055	367	137	f	\N	\N	2026-09-07 14:47:53.975058+07	6	manual	\N	\N	\N	{}	\N	\N
3056	367	97	f	\N	\N	2026-09-07 14:47:53.975058+07	7	manual	\N	\N	\N	{}	\N	\N
3057	367	91	f	\N	\N	2026-09-07 14:47:53.975058+07	13	manual	\N	\N	\N	{}	\N	\N
3058	367	70	f	\N	\N	2026-09-07 14:47:53.975058+07	12	manual	\N	\N	\N	{}	\N	\N
3059	367	67	f	\N	\N	2026-09-07 14:47:53.975058+07	16	manual	\N	\N	\N	{}	\N	\N
3060	367	69	f	\N	\N	2026-09-07 14:47:53.975058+07	17	manual	\N	\N	\N	{}	\N	\N
3061	367	48	f	\N	\N	2026-09-07 14:47:53.975058+07	14	manual	\N	\N	\N	{}	\N	\N
3062	367	52	f	\N	\N	2026-09-07 14:47:53.975058+07	15	manual	\N	\N	\N	{}	\N	\N
3063	367	5	f	\N	\N	2026-09-07 14:47:53.975058+07	8	manual	\N	\N	\N	{}	\N	\N
3064	367	28	f	\N	\N	2026-09-07 14:47:53.975058+07	9	manual	\N	\N	\N	{}	\N	\N
3065	367	6	f	\N	\N	2026-09-07 14:47:53.975058+07	10	manual	\N	\N	\N	{}	\N	\N
3066	367	36	f	\N	\N	2026-09-07 14:47:53.975058+07	11	manual	\N	\N	\N	{}	\N	\N
3139	374	147	f	\N	\N	2026-09-07 14:47:54.015682+07	6	manual	\N	\N	\N	{}	\N	\N
3140	374	132	f	\N	\N	2026-09-07 14:47:54.015682+07	7	manual	\N	\N	\N	{}	\N	\N
3141	374	91	f	\N	\N	2026-09-07 14:47:54.015682+07	13	manual	\N	\N	\N	{}	\N	\N
3142	374	70	f	\N	\N	2026-09-07 14:47:54.015682+07	12	manual	\N	\N	\N	{}	\N	\N
3143	374	43	f	\N	\N	2026-09-07 14:47:54.015682+07	16	manual	\N	\N	\N	{}	\N	\N
3144	374	45	f	\N	\N	2026-09-07 14:47:54.015682+07	17	manual	\N	\N	\N	{}	\N	\N
3145	374	48	f	\N	\N	2026-09-07 14:47:54.015682+07	14	manual	\N	\N	\N	{}	\N	\N
3146	374	52	f	\N	\N	2026-09-07 14:47:54.015682+07	15	manual	\N	\N	\N	{}	\N	\N
3147	374	27	f	\N	\N	2026-09-07 14:47:54.015682+07	8	manual	\N	\N	\N	{}	\N	\N
3148	374	4	f	\N	\N	2026-09-07 14:47:54.015682+07	9	manual	\N	\N	\N	{}	\N	\N
3149	374	26	f	\N	\N	2026-09-07 14:47:54.015682+07	10	manual	\N	\N	\N	{}	\N	\N
3150	374	41	f	\N	\N	2026-09-07 14:47:54.015682+07	11	manual	\N	\N	\N	{}	\N	\N
3243	385	123	f	\N	\N	2026-09-07 14:47:54.078386+07	1	manual	\N	\N	\N	{}	\N	\N
3244	385	124	f	\N	\N	2026-09-07 14:47:54.078386+07	2	manual	\N	\N	\N	{}	\N	\N
3245	385	107	f	\N	\N	2026-09-07 14:47:54.078386+07	3	manual	\N	\N	\N	{}	\N	\N
3246	385	81	f	\N	\N	2026-09-07 14:47:54.078386+07	4	manual	\N	\N	\N	{}	\N	\N
3247	385	84	f	\N	\N	2026-09-07 14:47:54.078386+07	5	manual	\N	\N	\N	{}	\N	\N
3263	389	135	f	\N	\N	2026-09-07 14:47:54.098231+07	1	manual	\N	\N	\N	{}	\N	\N
3264	389	136	f	\N	\N	2026-09-07 14:47:54.098231+07	2	manual	\N	\N	\N	{}	\N	\N
3265	389	137	f	\N	\N	2026-09-07 14:47:54.098231+07	3	manual	\N	\N	\N	{}	\N	\N
3266	389	72	f	\N	\N	2026-09-07 14:47:54.098231+07	4	manual	\N	\N	\N	{}	\N	\N
3267	389	73	f	\N	\N	2026-09-07 14:47:54.098231+07	5	manual	\N	\N	\N	{}	\N	\N
3288	394	147	f	\N	\N	2026-09-07 14:47:54.123922+07	1	manual	\N	\N	\N	{}	\N	\N
3289	394	136	f	\N	\N	2026-09-07 14:47:54.123922+07	2	manual	\N	\N	\N	{}	\N	\N
3290	394	137	f	\N	\N	2026-09-07 14:47:54.123922+07	3	manual	\N	\N	\N	{}	\N	\N
3291	394	81	f	\N	\N	2026-09-07 14:47:54.123922+07	4	manual	\N	\N	\N	{}	\N	\N
3292	394	82	f	\N	\N	2026-09-07 14:47:54.123922+07	5	manual	\N	\N	\N	{}	\N	\N
3323	401	150	f	\N	\N	2026-09-07 14:47:54.16075+07	1	manual	\N	\N	\N	{}	\N	\N
3324	401	127	f	\N	\N	2026-09-07 14:47:54.16075+07	2	manual	\N	\N	\N	{}	\N	\N
3325	401	129	f	\N	\N	2026-09-07 14:47:54.16075+07	3	manual	\N	\N	\N	{}	\N	\N
3326	401	32	f	\N	\N	2026-09-07 14:47:54.16075+07	4	manual	\N	\N	\N	{}	\N	\N
3327	401	91	f	\N	\N	2026-09-07 14:47:54.16075+07	5	manual	\N	\N	\N	{}	\N	\N
3343	405	145	f	\N	\N	2026-09-07 14:47:54.181463+07	1	manual	\N	\N	\N	{}	\N	\N
3344	405	113	f	\N	\N	2026-09-07 14:47:54.181463+07	2	manual	\N	\N	\N	{}	\N	\N
3345	405	114	f	\N	\N	2026-09-07 14:47:54.181463+07	3	manual	\N	\N	\N	{}	\N	\N
3346	405	84	f	\N	\N	2026-09-07 14:47:54.181463+07	4	manual	\N	\N	\N	{}	\N	\N
3347	405	102	f	\N	\N	2026-09-07 14:47:54.181463+07	5	manual	\N	\N	\N	{}	\N	\N
3368	410	145	f	\N	\N	2026-09-07 14:47:54.209016+07	1	manual	\N	\N	\N	{}	\N	\N
3370	410	112	f	\N	\N	2026-09-07 14:47:54.209016+07	3	manual	\N	\N	\N	{}	\N	\N
3372	410	71	f	\N	\N	2026-09-07 14:47:54.209016+07	5	manual	\N	\N	\N	{}	\N	\N
4176	450	8	f	\N	\N	2026-09-19 14:44:26.888607+07	6	auto	\N	\N	\N	{}	\N	\N
4177	450	4	f	\N	\N	2026-09-19 14:44:26.888607+07	13	auto	\N	\N	\N	{}	\N	\N
4178	450	5	f	\N	\N	2026-09-19 14:44:26.888607+07	12	auto	\N	\N	\N	{}	\N	\N
4179	450	12	f	\N	\N	2026-09-19 14:44:26.888607+07	16	auto	\N	\N	\N	{}	\N	\N
4180	450	24	f	\N	\N	2026-09-19 14:44:26.888607+07	17	auto	\N	\N	\N	{}	\N	\N
4181	450	25	f	\N	\N	2026-09-19 14:44:26.888607+07	14	auto	\N	\N	\N	{}	\N	\N
4182	450	37	f	\N	\N	2026-09-19 14:44:26.888607+07	15	auto	\N	\N	\N	{}	\N	\N
4183	450	16	f	\N	\N	2026-09-19 14:44:26.888607+07	8	auto	\N	\N	\N	{}	\N	\N
4184	450	28	f	\N	\N	2026-09-19 14:44:26.888607+07	9	auto	\N	\N	\N	{}	\N	\N
4185	450	17	f	\N	\N	2026-09-19 14:44:26.888607+07	10	auto	\N	\N	\N	{}	\N	\N
16728	1572	108	f	\N	\N	2026-09-20 19:39:22.000365+07	27	auto	\N	\N	\N	{}	2026-12-13	\N
16729	1572	77	f	\N	\N	2026-09-20 19:39:22.000365+07	28	auto	\N	\N	\N	{}	2026-12-13	\N
16730	1572	93	f	\N	\N	2026-09-20 19:39:22.000365+07	27	auto	\N	\N	\N	{}	2026-12-14	\N
16731	1572	109	f	\N	\N	2026-09-20 19:39:22.000365+07	28	auto	\N	\N	\N	{}	2026-12-14	\N
16732	1572	97	f	\N	\N	2026-09-20 19:39:22.000365+07	27	auto	\N	\N	\N	{}	2026-12-15	\N
16735	1573	96	f	\N	\N	2026-09-20 19:39:22.333096+07	20	auto	\N	\N	\N	{}	\N	\N
16736	1573	26	f	\N	\N	2026-09-20 19:39:22.333096+07	21	auto	\N	\N	\N	{}	\N	\N
16737	1573	19	f	\N	\N	2026-09-20 19:39:22.333096+07	22	auto	\N	\N	\N	{}	\N	\N
16738	1573	18	f	\N	\N	2026-09-20 19:39:22.333096+07	23	auto	\N	\N	\N	{}	\N	\N
16739	1573	6	f	\N	\N	2026-09-20 19:39:22.333096+07	24	auto	\N	\N	\N	{}	\N	\N
16740	1573	7	f	\N	\N	2026-09-20 19:39:22.333096+07	25	auto	\N	\N	\N	{}	\N	\N
16741	1573	103	f	\N	\N	2026-09-20 19:39:22.333096+07	29	auto	\N	\N	\N	{}	\N	\N
16742	1573	95	f	\N	\N	2026-09-20 19:39:22.333096+07	30	auto	\N	\N	\N	{}	\N	\N
16743	1573	32	f	\N	\N	2026-09-20 19:39:22.333096+07	28	auto	\N	\N	\N	{}	2026-12-15	\N
16744	1573	94	f	\N	\N	2026-09-20 19:39:22.333096+07	27	auto	\N	\N	\N	{}	2026-12-16	\N
16745	1573	102	f	\N	\N	2026-09-20 19:39:22.333096+07	28	auto	\N	\N	\N	{}	2026-12-16	\N
16746	1573	105	f	\N	\N	2026-09-20 19:39:22.333096+07	27	auto	\N	\N	\N	{}	2026-12-17	\N
16747	1573	107	f	\N	\N	2026-09-20 19:39:22.333096+07	28	auto	\N	\N	\N	{}	2026-12-17	\N
16748	1573	14	f	\N	\N	2026-09-20 19:39:22.333096+07	27	auto	\N	\N	\N	{}	2026-12-18	\N
16751	1574	108	f	\N	\N	2026-09-20 19:39:22.617453+07	20	auto	\N	\N	\N	{}	\N	\N
16752	1574	2	f	\N	\N	2026-09-20 19:39:22.617453+07	21	auto	\N	\N	\N	{}	\N	\N
16753	1574	15	f	\N	\N	2026-09-20 19:39:22.617453+07	22	auto	\N	\N	\N	{}	\N	\N
16754	1574	27	f	\N	\N	2026-09-20 19:39:22.617453+07	23	auto	\N	\N	\N	{}	\N	\N
16755	1574	38	f	\N	\N	2026-09-20 19:39:22.617453+07	24	auto	\N	\N	\N	{}	\N	\N
16756	1574	39	f	\N	\N	2026-09-20 19:39:22.617453+07	25	auto	\N	\N	\N	{}	\N	\N
16757	1574	106	f	\N	\N	2026-09-20 19:39:22.617453+07	29	auto	\N	\N	\N	{}	\N	\N
16758	1574	93	f	\N	\N	2026-09-20 19:39:22.617453+07	30	auto	\N	\N	\N	{}	\N	\N
16759	1574	101	f	\N	\N	2026-09-20 19:39:22.617453+07	28	auto	\N	\N	\N	{}	2026-12-18	\N
16760	1574	43	f	\N	\N	2026-09-20 19:39:22.617453+07	27	auto	\N	\N	\N	{}	2026-12-19	\N
16761	1574	109	f	\N	\N	2026-09-20 19:39:22.617453+07	28	auto	\N	\N	\N	{}	2026-12-19	\N
16762	1574	51	f	\N	\N	2026-09-20 19:39:22.617453+07	27	auto	\N	\N	\N	{}	2026-12-20	\N
16763	1574	95	f	\N	\N	2026-09-20 19:39:22.617453+07	28	auto	\N	\N	\N	{}	2026-12-20	\N
16764	1574	99	f	\N	\N	2026-09-20 19:39:22.617453+07	27	auto	\N	\N	\N	{}	2026-12-21	\N
16765	1574	91	f	\N	\N	2026-09-20 19:39:22.617453+07	28	auto	\N	\N	\N	{}	2026-12-21	\N
16766	1574	16	f	\N	\N	2026-09-20 19:39:22.617453+07	27	auto	\N	\N	\N	{}	2026-12-22	\N
16769	1575	8	f	\N	\N	2026-09-20 19:39:22.961951+07	20	auto	\N	\N	\N	{}	\N	\N
16770	1575	19	f	\N	\N	2026-09-20 19:39:22.961951+07	21	auto	\N	\N	\N	{}	\N	\N
16771	1575	26	f	\N	\N	2026-09-20 19:39:22.961951+07	22	auto	\N	\N	\N	{}	\N	\N
16772	1575	18	f	\N	\N	2026-09-20 19:39:22.961951+07	23	auto	\N	\N	\N	{}	\N	\N
16773	1575	6	f	\N	\N	2026-09-20 19:39:22.961951+07	24	auto	\N	\N	\N	{}	\N	\N
16774	1575	7	f	\N	\N	2026-09-20 19:39:22.961951+07	25	auto	\N	\N	\N	{}	\N	\N
16775	1575	102	f	\N	\N	2026-09-20 19:39:22.961951+07	29	auto	\N	\N	\N	{}	\N	\N
16776	1575	107	f	\N	\N	2026-09-20 19:39:22.961951+07	30	auto	\N	\N	\N	{}	\N	\N
16777	1575	96	f	\N	\N	2026-09-20 19:39:22.961951+07	28	auto	\N	\N	\N	{}	2026-12-22	\N
16778	1575	49	f	\N	\N	2026-09-20 19:39:22.961951+07	27	auto	\N	\N	\N	{}	2026-12-23	\N
16779	1575	94	f	\N	\N	2026-09-20 19:39:22.961951+07	28	auto	\N	\N	\N	{}	2026-12-23	\N
16780	1575	97	f	\N	\N	2026-09-20 19:39:22.961951+07	27	auto	\N	\N	\N	{}	2026-12-24	\N
16781	1575	32	f	\N	\N	2026-09-20 19:39:22.961951+07	28	auto	\N	\N	\N	{}	2026-12-24	\N
16782	1575	65	f	\N	\N	2026-09-20 19:39:22.961951+07	27	auto	\N	\N	\N	{}	2026-12-25	\N
16785	1576	101	f	\N	\N	2026-09-20 19:39:23.257244+07	20	auto	\N	\N	\N	{}	\N	\N
16786	1576	14	f	\N	\N	2026-09-20 19:39:23.257244+07	21	auto	\N	\N	\N	{}	\N	\N
16787	1576	2	f	\N	\N	2026-09-20 19:39:23.257244+07	22	auto	\N	\N	\N	{}	\N	\N
16788	1576	15	f	\N	\N	2026-09-20 19:39:23.257244+07	23	auto	\N	\N	\N	{}	\N	\N
16789	1576	27	f	\N	\N	2026-09-20 19:39:23.257244+07	24	auto	\N	\N	\N	{}	\N	\N
16790	1576	38	f	\N	\N	2026-09-20 19:39:23.257244+07	25	auto	\N	\N	\N	{}	\N	\N
16791	1576	109	f	\N	\N	2026-09-20 19:39:23.257244+07	29	auto	\N	\N	\N	{}	\N	\N
16792	1576	39	f	\N	\N	2026-09-20 19:39:23.257244+07	30	auto	\N	\N	\N	{}	\N	\N
16793	1576	108	f	\N	\N	2026-09-20 19:39:23.257244+07	28	auto	\N	\N	\N	{}	2026-12-25	\N
16794	1576	95	f	\N	\N	2026-09-20 19:39:23.257244+07	27	auto	\N	\N	\N	{}	2026-12-26	\N
16795	1576	103	f	\N	\N	2026-09-20 19:39:23.257244+07	28	auto	\N	\N	\N	{}	2026-12-26	\N
16796	1576	99	f	\N	\N	2026-09-20 19:39:23.257244+07	27	auto	\N	\N	\N	{}	2026-12-27	\N
16797	1576	105	f	\N	\N	2026-09-20 19:39:23.257244+07	28	auto	\N	\N	\N	{}	2026-12-27	\N
16798	1576	45	f	\N	\N	2026-09-20 19:39:23.257244+07	27	auto	\N	\N	\N	{}	2026-12-28	\N
16799	1576	47	f	\N	\N	2026-09-20 19:39:23.257244+07	28	auto	\N	\N	\N	{}	2026-12-28	\N
16800	1576	73	f	\N	\N	2026-09-20 19:39:23.257244+07	27	auto	\N	\N	\N	{}	2026-12-29	\N
16802	1577	8	f	\N	\N	2026-09-20 19:39:23.61405+07	29	auto	\N	\N	\N	{}	\N	\N
16803	1577	106	f	\N	\N	2026-09-20 19:39:23.61405+07	30	auto	\N	\N	\N	{}	\N	\N
16804	1577	19	f	\N	\N	2026-09-20 19:39:23.61405+07	28	auto	\N	\N	\N	{}	2026-12-29	\N
16805	1577	18	f	\N	\N	2026-09-20 19:39:23.61405+07	27	auto	\N	\N	\N	{}	2026-12-30	\N
16806	1577	94	f	\N	\N	2026-09-20 19:39:23.61405+07	28	auto	\N	\N	\N	{}	2026-12-30	\N
16807	1577	6	f	\N	\N	2026-09-20 19:39:23.61405+07	27	auto	\N	\N	\N	{}	2026-12-31	\N
16808	1577	7	f	\N	\N	2026-09-20 19:39:23.61405+07	28	auto	\N	\N	\N	{}	2026-12-31	\N
16809	1577	87	f	\N	\N	2026-09-20 19:39:23.61405+07	27	auto	\N	\N	\N	{}	2027-01-01	\N
2899	354	99	f	\N	\N	2026-09-07 14:47:53.893914+07	6	manual	\N	\N	\N	{}	\N	\N
2900	354	101	f	\N	\N	2026-09-07 14:47:53.893914+07	7	manual	\N	\N	\N	{}	\N	\N
2901	354	75	f	\N	\N	2026-09-07 14:47:53.893914+07	13	manual	\N	\N	\N	{}	\N	\N
2902	354	76	f	\N	\N	2026-09-07 14:47:53.893914+07	12	manual	\N	\N	\N	{}	\N	\N
2903	354	53	f	\N	\N	2026-09-07 14:47:53.893914+07	16	manual	\N	\N	\N	{}	\N	\N
2904	354	51	f	\N	\N	2026-09-07 14:47:53.893914+07	17	manual	\N	\N	\N	{}	\N	\N
2905	354	60	f	\N	\N	2026-09-07 14:47:53.893914+07	14	manual	\N	\N	\N	{}	\N	\N
2906	354	64	f	\N	\N	2026-09-07 14:47:53.893914+07	15	manual	\N	\N	\N	{}	\N	\N
2907	354	18	f	\N	\N	2026-09-07 14:47:53.893914+07	8	manual	\N	\N	\N	{}	\N	\N
2908	354	38	f	\N	\N	2026-09-07 14:47:53.893914+07	9	manual	\N	\N	\N	{}	\N	\N
2909	354	54	f	\N	\N	2026-09-07 14:47:53.893914+07	10	manual	\N	\N	\N	{}	\N	\N
2910	354	16	f	\N	\N	2026-09-07 14:47:53.893914+07	11	manual	\N	\N	\N	{}	\N	\N
2959	359	118	f	\N	\N	2026-09-07 14:47:53.926698+07	6	manual	\N	\N	\N	{}	\N	\N
2960	359	119	f	\N	\N	2026-09-07 14:47:53.926698+07	7	manual	\N	\N	\N	{}	\N	\N
2961	359	89	f	\N	\N	2026-09-07 14:47:53.926698+07	13	manual	\N	\N	\N	{}	\N	\N
2962	359	5	f	\N	\N	2026-09-07 14:47:53.926698+07	12	manual	\N	\N	\N	{}	\N	\N
2963	359	47	f	\N	\N	2026-09-07 14:47:53.926698+07	16	manual	\N	\N	\N	{}	\N	\N
2964	359	49	f	\N	\N	2026-09-07 14:47:53.926698+07	17	manual	\N	\N	\N	{}	\N	\N
2965	359	66	f	\N	\N	2026-09-07 14:47:53.926698+07	14	manual	\N	\N	\N	{}	\N	\N
2966	359	25	f	\N	\N	2026-09-07 14:47:53.926698+07	15	manual	\N	\N	\N	{}	\N	\N
2967	359	54	f	\N	\N	2026-09-07 14:47:53.926698+07	8	manual	\N	\N	\N	{}	\N	\N
2968	359	16	f	\N	\N	2026-09-07 14:47:53.926698+07	9	manual	\N	\N	\N	{}	\N	\N
2969	359	18	f	\N	\N	2026-09-07 14:47:53.926698+07	10	manual	\N	\N	\N	{}	\N	\N
2970	359	41	f	\N	\N	2026-09-07 14:47:53.926698+07	11	manual	\N	\N	\N	{}	\N	\N
3019	364	131	f	\N	\N	2026-09-07 14:47:53.957383+07	6	manual	\N	\N	\N	{}	\N	\N
3020	364	132	f	\N	\N	2026-09-07 14:47:53.957383+07	7	manual	\N	\N	\N	{}	\N	\N
3021	364	85	f	\N	\N	2026-09-07 14:47:53.957383+07	13	manual	\N	\N	\N	{}	\N	\N
3022	364	90	f	\N	\N	2026-09-07 14:47:53.957383+07	12	manual	\N	\N	\N	{}	\N	\N
3023	364	43	f	\N	\N	2026-09-07 14:47:53.957383+07	16	manual	\N	\N	\N	{}	\N	\N
3024	364	45	f	\N	\N	2026-09-07 14:47:53.957383+07	17	manual	\N	\N	\N	{}	\N	\N
3025	364	58	f	\N	\N	2026-09-07 14:47:53.957383+07	14	manual	\N	\N	\N	{}	\N	\N
3026	364	52	f	\N	\N	2026-09-07 14:47:53.957383+07	15	manual	\N	\N	\N	{}	\N	\N
3027	364	27	f	\N	\N	2026-09-07 14:47:53.957383+07	8	manual	\N	\N	\N	{}	\N	\N
3028	364	25	f	\N	\N	2026-09-07 14:47:53.957383+07	9	manual	\N	\N	\N	{}	\N	\N
3029	364	54	f	\N	\N	2026-09-07 14:47:53.957383+07	10	manual	\N	\N	\N	{}	\N	\N
3067	368	138	f	\N	\N	2026-09-07 14:47:53.980923+07	6	manual	\N	\N	\N	{}	\N	\N
3068	368	99	f	\N	\N	2026-09-07 14:47:53.980923+07	7	manual	\N	\N	\N	{}	\N	\N
3069	368	77	f	\N	\N	2026-09-07 14:47:53.980923+07	13	manual	\N	\N	\N	{}	\N	\N
3070	368	72	f	\N	\N	2026-09-07 14:47:53.980923+07	12	manual	\N	\N	\N	{}	\N	\N
3071	368	43	f	\N	\N	2026-09-07 14:47:53.980923+07	16	manual	\N	\N	\N	{}	\N	\N
3072	368	45	f	\N	\N	2026-09-07 14:47:53.980923+07	17	manual	\N	\N	\N	{}	\N	\N
3073	368	58	f	\N	\N	2026-09-07 14:47:53.980923+07	14	manual	\N	\N	\N	{}	\N	\N
3074	368	60	f	\N	\N	2026-09-07 14:47:53.980923+07	15	manual	\N	\N	\N	{}	\N	\N
3075	368	7	f	\N	\N	2026-09-07 14:47:53.980923+07	8	manual	\N	\N	\N	{}	\N	\N
3076	368	38	f	\N	\N	2026-09-07 14:47:53.980923+07	9	manual	\N	\N	\N	{}	\N	\N
3077	368	54	f	\N	\N	2026-09-07 14:47:53.980923+07	10	manual	\N	\N	\N	{}	\N	\N
3078	368	41	f	\N	\N	2026-09-07 14:47:53.980923+07	11	manual	\N	\N	\N	{}	\N	\N
3115	372	144	f	\N	\N	2026-09-07 14:47:54.003912+07	6	manual	\N	\N	\N	{}	\N	\N
3116	372	109	f	\N	\N	2026-09-07 14:47:54.003912+07	7	manual	\N	\N	\N	{}	\N	\N
3117	372	87	f	\N	\N	2026-09-07 14:47:54.003912+07	13	manual	\N	\N	\N	{}	\N	\N
3118	372	82	f	\N	\N	2026-09-07 14:47:54.003912+07	12	manual	\N	\N	\N	{}	\N	\N
3119	372	63	f	\N	\N	2026-09-07 14:47:54.003912+07	16	manual	\N	\N	\N	{}	\N	\N
3120	372	65	f	\N	\N	2026-09-07 14:47:54.003912+07	17	manual	\N	\N	\N	{}	\N	\N
3121	372	58	f	\N	\N	2026-09-07 14:47:54.003912+07	14	manual	\N	\N	\N	{}	\N	\N
3122	372	60	f	\N	\N	2026-09-07 14:47:54.003912+07	15	manual	\N	\N	\N	{}	\N	\N
3123	372	54	f	\N	\N	2026-09-07 14:47:54.003912+07	8	manual	\N	\N	\N	{}	\N	\N
3124	372	2	f	\N	\N	2026-09-07 14:47:54.003912+07	9	manual	\N	\N	\N	{}	\N	\N
3125	372	15	f	\N	\N	2026-09-07 14:47:54.003912+07	10	manual	\N	\N	\N	{}	\N	\N
3126	372	12	f	\N	\N	2026-09-07 14:47:54.003912+07	11	manual	\N	\N	\N	{}	\N	\N
3163	376	148	f	\N	\N	2026-09-07 14:47:54.027215+07	6	manual	\N	\N	\N	{}	\N	\N
3164	376	135	f	\N	\N	2026-09-07 14:47:54.027215+07	7	manual	\N	\N	\N	{}	\N	\N
3165	376	75	f	\N	\N	2026-09-07 14:47:54.027215+07	13	manual	\N	\N	\N	{}	\N	\N
3166	376	78	f	\N	\N	2026-09-07 14:47:54.027215+07	12	manual	\N	\N	\N	{}	\N	\N
3167	376	63	f	\N	\N	2026-09-07 14:47:54.027215+07	16	manual	\N	\N	\N	{}	\N	\N
3168	376	65	f	\N	\N	2026-09-07 14:47:54.027215+07	17	manual	\N	\N	\N	{}	\N	\N
3169	376	42	f	\N	\N	2026-09-07 14:47:54.027215+07	14	manual	\N	\N	\N	{}	\N	\N
3170	376	46	f	\N	\N	2026-09-07 14:47:54.027215+07	15	manual	\N	\N	\N	{}	\N	\N
3171	376	27	f	\N	\N	2026-09-07 14:47:54.027215+07	8	manual	\N	\N	\N	{}	\N	\N
3172	376	4	f	\N	\N	2026-09-07 14:47:54.027215+07	9	manual	\N	\N	\N	{}	\N	\N
3173	376	54	f	\N	\N	2026-09-07 14:47:54.027215+07	10	manual	\N	\N	\N	{}	\N	\N
3174	376	12	f	\N	\N	2026-09-07 14:47:54.027215+07	11	manual	\N	\N	\N	{}	\N	\N
3211	380	138	f	\N	\N	2026-09-07 14:47:54.050619+07	6	manual	\N	\N	\N	{}	\N	\N
3212	380	105	f	\N	\N	2026-09-07 14:47:54.050619+07	7	manual	\N	\N	\N	{}	\N	\N
3213	380	87	f	\N	\N	2026-09-07 14:47:54.050619+07	13	manual	\N	\N	\N	{}	\N	\N
3214	380	70	f	\N	\N	2026-09-07 14:47:54.050619+07	12	manual	\N	\N	\N	{}	\N	\N
3215	380	43	f	\N	\N	2026-09-07 14:47:54.050619+07	16	manual	\N	\N	\N	{}	\N	\N
3216	380	45	f	\N	\N	2026-09-07 14:47:54.050619+07	17	manual	\N	\N	\N	{}	\N	\N
3217	380	42	f	\N	\N	2026-09-07 14:47:54.050619+07	14	manual	\N	\N	\N	{}	\N	\N
3218	380	46	f	\N	\N	2026-09-07 14:47:54.050619+07	15	manual	\N	\N	\N	{}	\N	\N
3219	380	19	f	\N	\N	2026-09-07 14:47:54.050619+07	8	manual	\N	\N	\N	{}	\N	\N
3220	380	37	f	\N	\N	2026-09-07 14:47:54.050619+07	9	manual	\N	\N	\N	{}	\N	\N
3221	380	55	f	\N	\N	2026-09-07 14:47:54.050619+07	10	manual	\N	\N	\N	{}	\N	\N
3222	380	41	f	\N	\N	2026-09-07 14:47:54.050619+07	11	manual	\N	\N	\N	{}	\N	\N
3238	384	119	f	\N	\N	2026-09-07 14:47:54.072552+07	1	manual	\N	\N	\N	{}	\N	\N
3239	384	121	f	\N	\N	2026-09-07 14:47:54.072552+07	2	manual	\N	\N	\N	{}	\N	\N
3240	384	105	f	\N	\N	2026-09-07 14:47:54.072552+07	3	manual	\N	\N	\N	{}	\N	\N
3241	384	67	f	\N	\N	2026-09-07 14:47:54.072552+07	4	manual	\N	\N	\N	{}	\N	\N
3242	384	69	f	\N	\N	2026-09-07 14:47:54.072552+07	5	manual	\N	\N	\N	{}	\N	\N
3273	391	143	f	\N	\N	2026-09-07 14:47:54.108795+07	1	manual	\N	\N	\N	{}	\N	\N
3274	391	9	f	\N	\N	2026-09-07 14:47:54.108795+07	2	manual	\N	\N	\N	{}	\N	\N
3275	391	34	f	\N	\N	2026-09-07 14:47:54.108795+07	3	manual	\N	\N	\N	{}	\N	\N
3276	391	85	f	\N	\N	2026-09-07 14:47:54.108795+07	4	manual	\N	\N	\N	{}	\N	\N
3277	391	88	f	\N	\N	2026-09-07 14:47:54.108795+07	5	manual	\N	\N	\N	{}	\N	\N
3298	396	149	f	\N	\N	2026-09-07 14:47:54.134447+07	1	manual	\N	\N	\N	{}	\N	\N
3299	396	142	f	\N	\N	2026-09-07 14:47:54.134447+07	2	manual	\N	\N	\N	{}	\N	\N
3300	396	143	f	\N	\N	2026-09-07 14:47:54.134447+07	3	manual	\N	\N	\N	{}	\N	\N
3301	396	103	f	\N	\N	2026-09-07 14:47:54.134447+07	4	manual	\N	\N	\N	{}	\N	\N
3302	396	106	f	\N	\N	2026-09-07 14:47:54.134447+07	5	manual	\N	\N	\N	{}	\N	\N
3318	400	149	f	\N	\N	2026-09-07 14:47:54.155683+07	1	manual	\N	\N	\N	{}	\N	\N
3319	400	125	f	\N	\N	2026-09-07 14:47:54.155683+07	2	manual	\N	\N	\N	{}	\N	\N
3320	400	106	f	\N	\N	2026-09-07 14:47:54.155683+07	3	manual	\N	\N	\N	{}	\N	\N
3321	400	109	f	\N	\N	2026-09-07 14:47:54.155683+07	4	manual	\N	\N	\N	{}	\N	\N
3322	400	8	f	\N	\N	2026-09-07 14:47:54.155683+07	5	manual	\N	\N	\N	{}	\N	\N
3338	404	144	f	\N	\N	2026-09-07 14:47:54.17564+07	1	manual	\N	\N	\N	{}	\N	\N
3339	404	111	f	\N	\N	2026-09-07 14:47:54.17564+07	2	manual	\N	\N	\N	{}	\N	\N
3340	404	112	f	\N	\N	2026-09-07 14:47:54.17564+07	3	manual	\N	\N	\N	{}	\N	\N
16811	1578	97	f	\N	\N	2026-09-20 19:39:23.984965+07	29	auto	\N	\N	\N	{}	\N	\N
16812	1578	93	f	\N	\N	2026-09-20 19:39:23.984965+07	30	auto	\N	\N	\N	{}	\N	\N
2923	356	105	f	\N	\N	2026-09-07 14:47:53.9084+07	6	manual	\N	\N	\N	{}	\N	\N
2924	356	106	f	\N	\N	2026-09-07 14:47:53.9084+07	7	manual	\N	\N	\N	{}	\N	\N
2925	356	83	f	\N	\N	2026-09-07 14:47:53.9084+07	13	manual	\N	\N	\N	{}	\N	\N
2926	356	82	f	\N	\N	2026-09-07 14:47:53.9084+07	12	manual	\N	\N	\N	{}	\N	\N
2927	356	63	f	\N	\N	2026-09-07 14:47:53.9084+07	16	manual	\N	\N	\N	{}	\N	\N
2928	356	65	f	\N	\N	2026-09-07 14:47:53.9084+07	17	manual	\N	\N	\N	{}	\N	\N
2929	356	46	f	\N	\N	2026-09-07 14:47:53.9084+07	14	manual	\N	\N	\N	{}	\N	\N
2930	356	48	f	\N	\N	2026-09-07 14:47:53.9084+07	15	manual	\N	\N	\N	{}	\N	\N
2931	356	7	f	\N	\N	2026-09-07 14:47:53.9084+07	8	manual	\N	\N	\N	{}	\N	\N
2932	356	38	f	\N	\N	2026-09-07 14:47:53.9084+07	9	manual	\N	\N	\N	{}	\N	\N
2933	356	18	f	\N	\N	2026-09-07 14:47:53.9084+07	10	manual	\N	\N	\N	{}	\N	\N
2934	356	41	f	\N	\N	2026-09-07 14:47:53.9084+07	11	manual	\N	\N	\N	{}	\N	\N
3007	363	129	f	\N	\N	2026-09-07 14:47:53.95123+07	6	manual	\N	\N	\N	{}	\N	\N
3008	363	130	f	\N	\N	2026-09-07 14:47:53.95123+07	7	manual	\N	\N	\N	{}	\N	\N
3009	363	75	f	\N	\N	2026-09-07 14:47:53.95123+07	13	manual	\N	\N	\N	{}	\N	\N
3010	363	88	f	\N	\N	2026-09-07 14:47:53.95123+07	12	manual	\N	\N	\N	{}	\N	\N
3011	363	63	f	\N	\N	2026-09-07 14:47:53.95123+07	16	manual	\N	\N	\N	{}	\N	\N
3012	363	65	f	\N	\N	2026-09-07 14:47:53.95123+07	17	manual	\N	\N	\N	{}	\N	\N
3013	363	48	f	\N	\N	2026-09-07 14:47:53.95123+07	14	manual	\N	\N	\N	{}	\N	\N
3014	363	66	f	\N	\N	2026-09-07 14:47:53.95123+07	15	manual	\N	\N	\N	{}	\N	\N
3015	363	15	f	\N	\N	2026-09-07 14:47:53.95123+07	8	manual	\N	\N	\N	{}	\N	\N
3016	363	12	f	\N	\N	2026-09-07 14:47:53.95123+07	9	manual	\N	\N	\N	{}	\N	\N
3017	363	26	f	\N	\N	2026-09-07 14:47:53.95123+07	10	manual	\N	\N	\N	{}	\N	\N
3018	363	24	f	\N	\N	2026-09-07 14:47:53.95123+07	11	manual	\N	\N	\N	{}	\N	\N
16813	1578	26	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-01	\N
3080	369	101	f	\N	\N	2026-09-07 14:47:53.986865+07	7	manual	\N	\N	\N	{}	\N	\N
3081	369	83	f	\N	\N	2026-09-07 14:47:53.986865+07	13	manual	\N	\N	\N	{}	\N	\N
3082	369	90	f	\N	\N	2026-09-07 14:47:53.986865+07	12	manual	\N	\N	\N	{}	\N	\N
3083	369	47	f	\N	\N	2026-09-07 14:47:53.986865+07	16	manual	\N	\N	\N	{}	\N	\N
3084	369	49	f	\N	\N	2026-09-07 14:47:53.986865+07	17	manual	\N	\N	\N	{}	\N	\N
3085	369	64	f	\N	\N	2026-09-07 14:47:53.986865+07	14	manual	\N	\N	\N	{}	\N	\N
3086	369	66	f	\N	\N	2026-09-07 14:47:53.986865+07	15	manual	\N	\N	\N	{}	\N	\N
3087	369	5	f	\N	\N	2026-09-07 14:47:53.986865+07	8	manual	\N	\N	\N	{}	\N	\N
3088	369	37	f	\N	\N	2026-09-07 14:47:53.986865+07	9	manual	\N	\N	\N	{}	\N	\N
3089	369	55	f	\N	\N	2026-09-07 14:47:53.986865+07	10	manual	\N	\N	\N	{}	\N	\N
3090	369	17	f	\N	\N	2026-09-07 14:47:53.986865+07	11	manual	\N	\N	\N	{}	\N	\N
3127	373	145	f	\N	\N	2026-09-07 14:47:54.009928+07	6	manual	\N	\N	\N	{}	\N	\N
3128	373	131	f	\N	\N	2026-09-07 14:47:54.009928+07	7	manual	\N	\N	\N	{}	\N	\N
3129	373	89	f	\N	\N	2026-09-07 14:47:54.009928+07	13	manual	\N	\N	\N	{}	\N	\N
3130	373	88	f	\N	\N	2026-09-07 14:47:54.009928+07	12	manual	\N	\N	\N	{}	\N	\N
3131	373	67	f	\N	\N	2026-09-07 14:47:54.009928+07	16	manual	\N	\N	\N	{}	\N	\N
3132	373	69	f	\N	\N	2026-09-07 14:47:54.009928+07	17	manual	\N	\N	\N	{}	\N	\N
3133	373	64	f	\N	\N	2026-09-07 14:47:54.009928+07	14	manual	\N	\N	\N	{}	\N	\N
3134	373	66	f	\N	\N	2026-09-07 14:47:54.009928+07	15	manual	\N	\N	\N	{}	\N	\N
3135	373	18	f	\N	\N	2026-09-07 14:47:54.009928+07	8	manual	\N	\N	\N	{}	\N	\N
3136	373	24	f	\N	\N	2026-09-07 14:47:54.009928+07	9	manual	\N	\N	\N	{}	\N	\N
3137	373	38	f	\N	\N	2026-09-07 14:47:54.009928+07	10	manual	\N	\N	\N	{}	\N	\N
3138	373	37	f	\N	\N	2026-09-07 14:47:54.009928+07	11	manual	\N	\N	\N	{}	\N	\N
3175	377	149	f	\N	\N	2026-09-07 14:47:54.033146+07	6	manual	\N	\N	\N	{}	\N	\N
3176	377	136	f	\N	\N	2026-09-07 14:47:54.033146+07	7	manual	\N	\N	\N	{}	\N	\N
3177	377	77	f	\N	\N	2026-09-07 14:47:54.033146+07	13	manual	\N	\N	\N	{}	\N	\N
3178	377	82	f	\N	\N	2026-09-07 14:47:54.033146+07	12	manual	\N	\N	\N	{}	\N	\N
3179	377	67	f	\N	\N	2026-09-07 14:47:54.033146+07	16	manual	\N	\N	\N	{}	\N	\N
3180	377	69	f	\N	\N	2026-09-07 14:47:54.033146+07	17	manual	\N	\N	\N	{}	\N	\N
3181	377	64	f	\N	\N	2026-09-07 14:47:54.033146+07	14	manual	\N	\N	\N	{}	\N	\N
3182	377	66	f	\N	\N	2026-09-07 14:47:54.033146+07	15	manual	\N	\N	\N	{}	\N	\N
3183	377	19	f	\N	\N	2026-09-07 14:47:54.033146+07	8	manual	\N	\N	\N	{}	\N	\N
3184	377	15	f	\N	\N	2026-09-07 14:47:54.033146+07	9	manual	\N	\N	\N	{}	\N	\N
3185	377	26	f	\N	\N	2026-09-07 14:47:54.033146+07	10	manual	\N	\N	\N	{}	\N	\N
3186	377	24	f	\N	\N	2026-09-07 14:47:54.033146+07	11	manual	\N	\N	\N	{}	\N	\N
3223	381	112	f	\N	\N	2026-09-07 14:47:54.056603+07	1	manual	\N	\N	\N	{}	\N	\N
3224	381	113	f	\N	\N	2026-09-07 14:47:54.056603+07	2	manual	\N	\N	\N	{}	\N	\N
3225	381	96	f	\N	\N	2026-09-07 14:47:54.056603+07	3	manual	\N	\N	\N	{}	\N	\N
3226	381	39	f	\N	\N	2026-09-07 14:47:54.056603+07	4	manual	\N	\N	\N	{}	\N	\N
3227	381	57	f	\N	\N	2026-09-07 14:47:54.056603+07	5	manual	\N	\N	\N	{}	\N	\N
3248	386	125	f	\N	\N	2026-09-07 14:47:54.083836+07	1	manual	\N	\N	\N	{}	\N	\N
3249	386	126	f	\N	\N	2026-09-07 14:47:54.083836+07	2	manual	\N	\N	\N	{}	\N	\N
3250	386	109	f	\N	\N	2026-09-07 14:47:54.083836+07	3	manual	\N	\N	\N	{}	\N	\N
3251	386	87	f	\N	\N	2026-09-07 14:47:54.083836+07	4	manual	\N	\N	\N	{}	\N	\N
3252	386	89	f	\N	\N	2026-09-07 14:47:54.083836+07	5	manual	\N	\N	\N	{}	\N	\N
3268	390	138	f	\N	\N	2026-09-07 14:47:54.103609+07	1	manual	\N	\N	\N	{}	\N	\N
3269	390	139	f	\N	\N	2026-09-07 14:47:54.103609+07	2	manual	\N	\N	\N	{}	\N	\N
3270	390	142	f	\N	\N	2026-09-07 14:47:54.103609+07	3	manual	\N	\N	\N	{}	\N	\N
3271	390	75	f	\N	\N	2026-09-07 14:47:54.103609+07	4	manual	\N	\N	\N	{}	\N	\N
3272	390	76	f	\N	\N	2026-09-07 14:47:54.103609+07	5	manual	\N	\N	\N	{}	\N	\N
3293	395	148	f	\N	\N	2026-09-07 14:47:54.12898+07	1	manual	\N	\N	\N	{}	\N	\N
3294	395	138	f	\N	\N	2026-09-07 14:47:54.12898+07	2	manual	\N	\N	\N	{}	\N	\N
3295	395	139	f	\N	\N	2026-09-07 14:47:54.12898+07	3	manual	\N	\N	\N	{}	\N	\N
3296	395	83	f	\N	\N	2026-09-07 14:47:54.12898+07	4	manual	\N	\N	\N	{}	\N	\N
3297	395	84	f	\N	\N	2026-09-07 14:47:54.12898+07	5	manual	\N	\N	\N	{}	\N	\N
3313	399	148	f	\N	\N	2026-09-07 14:47:54.150757+07	1	manual	\N	\N	\N	{}	\N	\N
3314	399	132	f	\N	\N	2026-09-07 14:47:54.150757+07	2	manual	\N	\N	\N	{}	\N	\N
3315	399	135	f	\N	\N	2026-09-07 14:47:54.150757+07	3	manual	\N	\N	\N	{}	\N	\N
3316	399	103	f	\N	\N	2026-09-07 14:47:54.150757+07	4	manual	\N	\N	\N	{}	\N	\N
3317	399	105	f	\N	\N	2026-09-07 14:47:54.150757+07	5	manual	\N	\N	\N	{}	\N	\N
3333	403	150	f	\N	\N	2026-09-07 14:47:54.170384+07	1	manual	\N	\N	\N	{}	\N	\N
3334	403	22	f	\N	\N	2026-09-07 14:47:54.170384+07	2	manual	\N	\N	\N	{}	\N	\N
3335	403	34	f	\N	\N	2026-09-07 14:47:54.170384+07	3	manual	\N	\N	\N	{}	\N	\N
3336	403	99	f	\N	\N	2026-09-07 14:47:54.170384+07	4	manual	\N	\N	\N	{}	\N	\N
3337	403	73	f	\N	\N	2026-09-07 14:47:54.170384+07	5	manual	\N	\N	\N	{}	\N	\N
3358	408	130	f	\N	\N	2026-09-07 14:47:54.197879+07	1	manual	\N	\N	\N	{}	\N	\N
3359	408	139	f	\N	\N	2026-09-07 14:47:54.197879+07	2	manual	\N	\N	\N	{}	\N	\N
3360	408	142	f	\N	\N	2026-09-07 14:47:54.197879+07	3	manual	\N	\N	\N	{}	\N	\N
16814	1578	96	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-02	\N
3362	408	94	f	\N	\N	2026-09-07 14:47:54.197879+07	5	manual	\N	\N	\N	{}	\N	\N
16815	1578	103	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-02	\N
16816	1578	102	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-03	\N
16817	1578	39	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-03	\N
16818	1578	14	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-04	\N
16819	1578	101	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-04	\N
16820	1578	15	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-05	\N
16823	1579	7	f	\N	\N	2026-09-20 19:39:23.984965+07	21	auto	\N	\N	\N	{}	\N	\N
16824	1579	25	f	\N	\N	2026-09-20 19:39:23.984965+07	22	auto	\N	\N	\N	{}	\N	\N
16825	1579	17	f	\N	\N	2026-09-20 19:39:23.984965+07	23	auto	\N	\N	\N	{}	\N	\N
16826	1579	18	f	\N	\N	2026-09-20 19:39:23.984965+07	24	auto	\N	\N	\N	{}	\N	\N
16827	1579	95	f	\N	\N	2026-09-20 19:39:23.984965+07	29	auto	\N	\N	\N	{}	\N	\N
16828	1579	107	f	\N	\N	2026-09-20 19:39:23.984965+07	30	auto	\N	\N	\N	{}	\N	\N
16829	1579	105	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-05	\N
16830	1579	99	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-06	\N
16831	1579	106	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-06	\N
16832	1579	108	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-07	\N
16833	1579	109	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-07	\N
16834	1579	94	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-08	\N
16837	1580	36	f	\N	\N	2026-09-20 19:39:23.984965+07	21	auto	\N	\N	\N	{}	\N	\N
16838	1580	19	f	\N	\N	2026-09-20 19:39:23.984965+07	22	auto	\N	\N	\N	{}	\N	\N
16839	1580	4	f	\N	\N	2026-09-20 19:39:23.984965+07	23	auto	\N	\N	\N	{}	\N	\N
16840	1580	37	f	\N	\N	2026-09-20 19:39:23.984965+07	24	auto	\N	\N	\N	{}	\N	\N
16841	1580	27	f	\N	\N	2026-09-20 19:39:23.984965+07	25	auto	\N	\N	\N	{}	\N	\N
16842	1580	51	f	\N	\N	2026-09-20 19:39:23.984965+07	29	auto	\N	\N	\N	{}	\N	\N
16843	1580	73	f	\N	\N	2026-09-20 19:39:23.984965+07	30	auto	\N	\N	\N	{}	\N	\N
16844	1580	28	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-08	\N
16845	1580	71	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-09	\N
16846	1580	45	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-09	\N
16847	1580	46	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-10	\N
16848	1580	47	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-10	\N
16849	1580	48	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-11	\N
16850	1580	82	f	\N	\N	2026-09-20 19:39:23.984965+07	28	auto	\N	\N	\N	{}	2027-01-11	\N
16851	1580	53	f	\N	\N	2026-09-20 19:39:23.984965+07	27	auto	\N	\N	\N	{}	2027-01-12	\N
16854	1581	107	f	\N	\N	2026-09-20 19:39:24.924205+07	20	auto	\N	\N	\N	{}	\N	\N
16855	1581	12	f	\N	\N	2026-09-20 19:39:24.924205+07	29	auto	\N	\N	\N	{}	\N	\N
16856	1581	69	f	\N	\N	2026-09-20 19:39:24.924205+07	30	auto	\N	\N	\N	{}	\N	\N
16857	1581	57	f	\N	\N	2026-09-20 19:39:24.924205+07	28	auto	\N	\N	\N	{}	2027-01-12	\N
16858	1581	61	f	\N	\N	2026-09-20 19:39:24.924205+07	27	auto	\N	\N	\N	{}	2027-01-13	\N
16859	1581	67	f	\N	\N	2026-09-20 19:39:24.924205+07	28	auto	\N	\N	\N	{}	2027-01-13	\N
16860	1581	81	f	\N	\N	2026-09-20 19:39:24.924205+07	27	auto	\N	\N	\N	{}	2027-01-14	\N
16861	1581	49	f	\N	\N	2026-09-20 19:39:24.924205+07	28	auto	\N	\N	\N	{}	2027-01-14	\N
16862	1581	70	f	\N	\N	2026-09-20 19:39:24.924205+07	27	auto	\N	\N	\N	{}	2027-01-15	\N
16865	1582	97	f	\N	\N	2026-09-20 19:39:25.241955+07	20	auto	\N	\N	\N	{}	\N	\N
16866	1582	6	f	\N	\N	2026-09-20 19:39:25.241955+07	21	auto	\N	\N	\N	{}	\N	\N
16867	1582	14	f	\N	\N	2026-09-20 19:39:25.241955+07	22	auto	\N	\N	\N	{}	\N	\N
16868	1582	7	f	\N	\N	2026-09-20 19:39:25.241955+07	23	auto	\N	\N	\N	{}	\N	\N
16869	1582	109	f	\N	\N	2026-09-20 19:39:25.241955+07	29	auto	\N	\N	\N	{}	\N	\N
16870	1582	94	f	\N	\N	2026-09-20 19:39:25.241955+07	30	auto	\N	\N	\N	{}	\N	\N
16871	1582	89	f	\N	\N	2026-09-20 19:39:25.241955+07	28	auto	\N	\N	\N	{}	2027-01-15	\N
16872	1582	24	f	\N	\N	2026-09-20 19:39:25.241955+07	27	auto	\N	\N	\N	{}	2027-01-16	\N
16873	1582	32	f	\N	\N	2026-09-20 19:39:25.241955+07	28	auto	\N	\N	\N	{}	2027-01-16	\N
16874	1582	102	f	\N	\N	2026-09-20 19:39:25.241955+07	27	auto	\N	\N	\N	{}	2027-01-17	\N
16875	1582	95	f	\N	\N	2026-09-20 19:39:25.241955+07	28	auto	\N	\N	\N	{}	2027-01-17	\N
16876	1582	87	f	\N	\N	2026-09-20 19:39:25.241955+07	27	auto	\N	\N	\N	{}	2027-01-18	\N
16877	1582	38	f	\N	\N	2026-09-20 19:39:25.241955+07	28	auto	\N	\N	\N	{}	2027-01-18	\N
16878	1582	66	f	\N	\N	2026-09-20 19:39:25.241955+07	27	auto	\N	\N	\N	{}	2027-01-19	\N
16881	1583	105	f	\N	\N	2026-09-20 19:39:25.635389+07	20	auto	\N	\N	\N	{}	\N	\N
16882	1583	39	f	\N	\N	2026-09-20 19:39:25.635389+07	21	auto	\N	\N	\N	{}	\N	\N
16883	1583	15	f	\N	\N	2026-09-20 19:39:25.635389+07	29	auto	\N	\N	\N	{}	\N	\N
16884	1583	101	f	\N	\N	2026-09-20 19:39:25.635389+07	30	auto	\N	\N	\N	{}	\N	\N
16885	1583	99	f	\N	\N	2026-09-20 19:39:25.635389+07	28	auto	\N	\N	\N	{}	2027-01-19	\N
16886	1583	83	f	\N	\N	2026-09-20 19:39:25.635389+07	27	auto	\N	\N	\N	{}	2027-01-20	\N
16887	1583	85	f	\N	\N	2026-09-20 19:39:25.635389+07	28	auto	\N	\N	\N	{}	2027-01-20	\N
16888	1583	103	f	\N	\N	2026-09-20 19:39:25.635389+07	27	auto	\N	\N	\N	{}	2027-01-21	\N
16889	1583	26	f	\N	\N	2026-09-20 19:39:25.635389+07	28	auto	\N	\N	\N	{}	2027-01-21	\N
16890	1583	2	f	\N	\N	2026-09-20 19:39:25.635389+07	27	auto	\N	\N	\N	{}	2027-01-22	\N
16893	1584	8	f	\N	\N	2026-09-20 19:39:25.968981+07	20	auto	\N	\N	\N	{}	\N	\N
16894	1584	106	f	\N	\N	2026-09-20 19:39:25.968981+07	29	auto	\N	\N	\N	{}	\N	\N
16895	1584	32	f	\N	\N	2026-09-20 19:39:25.968981+07	30	auto	\N	\N	\N	{}	\N	\N
16896	1584	19	f	\N	\N	2026-09-20 19:39:25.968981+07	28	auto	\N	\N	\N	{}	2027-01-22	\N
16897	1584	91	f	\N	\N	2026-09-20 19:39:25.968981+07	27	auto	\N	\N	\N	{}	2027-01-23	\N
16898	1584	27	f	\N	\N	2026-09-20 19:39:25.968981+07	28	auto	\N	\N	\N	{}	2027-01-23	\N
16899	1584	93	f	\N	\N	2026-09-20 19:39:25.968981+07	27	auto	\N	\N	\N	{}	2027-01-24	\N
16900	1584	96	f	\N	\N	2026-09-20 19:39:25.968981+07	28	auto	\N	\N	\N	{}	2027-01-24	\N
16901	1584	18	f	\N	\N	2026-09-20 19:39:25.968981+07	27	auto	\N	\N	\N	{}	2027-01-25	\N
16902	1584	16	f	\N	\N	2026-09-20 19:39:25.968981+07	28	auto	\N	\N	\N	{}	2027-01-25	\N
16903	1584	41	f	\N	\N	2026-09-20 19:39:25.968981+07	27	auto	\N	\N	\N	{}	2027-01-26	\N
16906	1585	108	f	\N	\N	2026-09-20 19:39:26.373959+07	20	auto	\N	\N	\N	{}	\N	\N
16907	1585	15	f	\N	\N	2026-09-20 19:39:26.373959+07	21	auto	\N	\N	\N	{}	\N	\N
16908	1585	26	f	\N	\N	2026-09-20 19:39:26.373959+07	22	auto	\N	\N	\N	{}	\N	\N
16909	1585	19	f	\N	\N	2026-09-20 19:39:26.373959+07	23	auto	\N	\N	\N	{}	\N	\N
16910	1585	18	f	\N	\N	2026-09-20 19:39:26.373959+07	24	auto	\N	\N	\N	{}	\N	\N
16911	1585	102	f	\N	\N	2026-09-20 19:39:26.373959+07	29	auto	\N	\N	\N	{}	\N	\N
16912	1585	6	f	\N	\N	2026-09-20 19:39:26.373959+07	30	auto	\N	\N	\N	{}	\N	\N
16913	1585	94	f	\N	\N	2026-09-20 19:39:26.373959+07	28	auto	\N	\N	\N	{}	2027-01-26	\N
16914	1585	2	f	\N	\N	2026-09-20 19:39:26.373959+07	27	auto	\N	\N	\N	{}	2027-01-27	\N
16915	1585	95	f	\N	\N	2026-09-20 19:39:26.373959+07	28	auto	\N	\N	\N	{}	2027-01-27	\N
16916	1585	97	f	\N	\N	2026-09-20 19:39:26.373959+07	27	auto	\N	\N	\N	{}	2027-01-28	\N
16917	1585	99	f	\N	\N	2026-09-20 19:39:26.373959+07	28	auto	\N	\N	\N	{}	2027-01-28	\N
16918	1585	65	f	\N	\N	2026-09-20 19:39:26.373959+07	27	auto	\N	\N	\N	{}	2027-01-29	\N
16921	1586	101	f	\N	\N	2026-09-20 19:39:26.711484+07	20	auto	\N	\N	\N	{}	\N	\N
16922	1586	38	f	\N	\N	2026-09-20 19:39:26.711484+07	21	auto	\N	\N	\N	{}	\N	\N
16923	1586	27	f	\N	\N	2026-09-20 19:39:26.711484+07	22	auto	\N	\N	\N	{}	\N	\N
16924	1586	39	f	\N	\N	2026-09-20 19:39:26.711484+07	23	auto	\N	\N	\N	{}	\N	\N
16925	1586	109	f	\N	\N	2026-09-20 19:39:26.711484+07	29	auto	\N	\N	\N	{}	\N	\N
16926	1586	103	f	\N	\N	2026-09-20 19:39:26.711484+07	30	auto	\N	\N	\N	{}	\N	\N
16927	1586	14	f	\N	\N	2026-09-20 19:39:26.711484+07	28	auto	\N	\N	\N	{}	2027-01-29	\N
16928	1586	107	f	\N	\N	2026-09-20 19:39:26.711484+07	27	auto	\N	\N	\N	{}	2027-01-30	\N
16929	1586	7	f	\N	\N	2026-09-20 19:39:26.711484+07	28	auto	\N	\N	\N	{}	2027-01-30	\N
16930	1586	75	f	\N	\N	2026-09-20 19:39:26.711484+07	27	auto	\N	\N	\N	{}	2027-01-31	\N
16931	1586	77	f	\N	\N	2026-09-20 19:39:26.711484+07	28	auto	\N	\N	\N	{}	2027-01-31	\N
16932	1586	89	f	\N	\N	2026-09-20 19:39:26.711484+07	27	auto	\N	\N	\N	{}	2027-02-01	\N
16933	1586	43	f	\N	\N	2026-09-20 19:39:26.711484+07	28	auto	\N	\N	\N	{}	2027-02-01	\N
16934	1586	28	f	\N	\N	2026-09-20 19:39:26.711484+07	27	auto	\N	\N	\N	{}	2027-02-02	\N
16935	1587	150	f	\N	\N	2026-09-26 16:41:07.400934+07	6	auto	\N	\N	\N	{}	\N	\N
16936	1587	126	f	\N	\N	2026-09-26 16:41:07.400934+07	7	auto	\N	\N	\N	{}	\N	\N
16937	1587	73	f	\N	\N	2026-09-26 16:41:07.400934+07	13	auto	\N	\N	\N	{}	\N	\N
16938	1587	17	f	\N	\N	2026-09-26 16:41:07.400934+07	12	auto	\N	\N	\N	{}	\N	\N
16939	1587	61	f	\N	\N	2026-09-26 16:41:07.400934+07	16	auto	\N	\N	\N	{}	\N	\N
16940	1587	63	f	\N	\N	2026-09-26 16:41:07.400934+07	17	auto	\N	\N	\N	{}	\N	\N
16941	1587	64	f	\N	\N	2026-09-26 16:41:07.400934+07	14	auto	\N	\N	\N	{}	\N	\N
16942	1587	66	f	\N	\N	2026-09-26 16:41:07.400934+07	15	auto	\N	\N	\N	{}	\N	\N
16943	1587	77	f	\N	\N	2026-09-26 16:41:07.400934+07	8	auto	\N	\N	\N	{}	\N	\N
16944	1587	65	f	\N	\N	2026-09-26 16:41:07.400934+07	9	auto	\N	\N	\N	{}	\N	\N
16945	1587	84	f	\N	\N	2026-09-26 16:41:07.400934+07	10	auto	\N	\N	\N	{}	\N	\N
16946	1587	82	f	\N	\N	2026-09-26 16:41:07.400934+07	11	auto	\N	\N	\N	{}	\N	\N
16947	1588	139	f	\N	\N	2026-09-26 16:41:07.531386+07	6	auto	\N	\N	\N	{}	\N	\N
16948	1588	111	f	\N	\N	2026-09-26 16:41:07.531386+07	7	auto	\N	\N	\N	{}	\N	\N
16949	1588	75	f	\N	\N	2026-09-26 16:41:07.531386+07	13	auto	\N	\N	\N	{}	\N	\N
16950	1588	78	f	\N	\N	2026-09-26 16:41:07.531386+07	12	auto	\N	\N	\N	{}	\N	\N
16951	1588	12	f	\N	\N	2026-09-26 16:41:07.531386+07	16	auto	\N	\N	\N	{}	\N	\N
16952	1588	67	f	\N	\N	2026-09-26 16:41:07.531386+07	17	auto	\N	\N	\N	{}	\N	\N
16953	1588	48	f	\N	\N	2026-09-26 16:41:07.531386+07	14	auto	\N	\N	\N	{}	\N	\N
16954	1588	52	f	\N	\N	2026-09-26 16:41:07.531386+07	15	auto	\N	\N	\N	{}	\N	\N
16955	1588	88	f	\N	\N	2026-09-26 16:41:07.531386+07	8	auto	\N	\N	\N	{}	\N	\N
16956	1588	90	f	\N	\N	2026-09-26 16:41:07.531386+07	9	auto	\N	\N	\N	{}	\N	\N
16957	1588	83	f	\N	\N	2026-09-26 16:41:07.531386+07	10	auto	\N	\N	\N	{}	\N	\N
16958	1588	69	f	\N	\N	2026-09-26 16:41:07.531386+07	11	auto	\N	\N	\N	{}	\N	\N
16959	1589	114	f	\N	\N	2026-09-26 16:41:07.646237+07	6	auto	\N	\N	\N	{}	\N	\N
16960	1589	113	f	\N	\N	2026-09-26 16:41:07.646237+07	7	auto	\N	\N	\N	{}	\N	\N
16961	1589	71	f	\N	\N	2026-09-26 16:41:07.646237+07	13	auto	\N	\N	\N	{}	\N	\N
16962	1589	76	f	\N	\N	2026-09-26 16:41:07.646237+07	12	auto	\N	\N	\N	{}	\N	\N
16963	1589	47	f	\N	\N	2026-09-26 16:41:07.646237+07	16	auto	\N	\N	\N	{}	\N	\N
16964	1589	49	f	\N	\N	2026-09-26 16:41:07.646237+07	17	auto	\N	\N	\N	{}	\N	\N
16965	1589	54	f	\N	\N	2026-09-26 16:41:07.646237+07	14	auto	\N	\N	\N	{}	\N	\N
16966	1589	60	f	\N	\N	2026-09-26 16:41:07.646237+07	15	auto	\N	\N	\N	{}	\N	\N
16967	1589	85	f	\N	\N	2026-09-26 16:41:07.646237+07	8	auto	\N	\N	\N	{}	\N	\N
16968	1589	51	f	\N	\N	2026-09-26 16:41:07.646237+07	9	auto	\N	\N	\N	{}	\N	\N
16969	1589	70	f	\N	\N	2026-09-26 16:41:07.646237+07	10	auto	\N	\N	\N	{}	\N	\N
16970	1589	42	f	\N	\N	2026-09-26 16:41:07.646237+07	11	auto	\N	\N	\N	{}	\N	\N
16971	1590	115	f	\N	\N	2026-09-26 16:41:07.646237+07	6	auto	\N	\N	\N	{}	\N	\N
16972	1590	9	f	\N	\N	2026-09-26 16:41:07.646237+07	7	auto	\N	\N	\N	{}	\N	\N
16973	1590	77	f	\N	\N	2026-09-26 16:41:07.646237+07	13	auto	\N	\N	\N	{}	\N	\N
16974	1590	29	f	\N	\N	2026-09-26 16:41:07.646237+07	12	auto	\N	\N	\N	{}	\N	\N
16975	1590	53	f	\N	\N	2026-09-26 16:41:07.646237+07	16	auto	\N	\N	\N	{}	\N	\N
16976	1590	43	f	\N	\N	2026-09-26 16:41:07.646237+07	17	auto	\N	\N	\N	{}	\N	\N
16977	1590	58	f	\N	\N	2026-09-26 16:41:07.646237+07	14	auto	\N	\N	\N	{}	\N	\N
16978	1590	46	f	\N	\N	2026-09-26 16:41:07.646237+07	15	auto	\N	\N	\N	{}	\N	\N
16979	1590	5	f	\N	\N	2026-09-26 16:41:07.646237+07	8	auto	\N	\N	\N	{}	\N	\N
16980	1590	37	f	\N	\N	2026-09-26 16:41:07.646237+07	9	auto	\N	\N	\N	{}	\N	\N
16981	1590	89	f	\N	\N	2026-09-26 16:41:07.646237+07	10	auto	\N	\N	\N	{}	\N	\N
16982	1590	45	f	\N	\N	2026-09-26 16:41:07.646237+07	11	auto	\N	\N	\N	{}	\N	\N
16983	1591	148	f	\N	\N	2026-09-26 16:41:07.646237+07	6	auto	\N	\N	\N	{}	\N	\N
16984	1591	135	f	\N	\N	2026-09-26 16:41:07.646237+07	7	auto	\N	\N	\N	{}	\N	\N
16985	1591	87	f	\N	\N	2026-09-26 16:41:07.646237+07	13	auto	\N	\N	\N	{}	\N	\N
16986	1591	82	f	\N	\N	2026-09-26 16:41:07.646237+07	12	auto	\N	\N	\N	{}	\N	\N
16987	1591	55	f	\N	\N	2026-09-26 16:41:07.646237+07	16	auto	\N	\N	\N	{}	\N	\N
16988	1591	41	f	\N	\N	2026-09-26 16:41:07.646237+07	17	auto	\N	\N	\N	{}	\N	\N
16989	1591	64	f	\N	\N	2026-09-26 16:41:07.646237+07	14	auto	\N	\N	\N	{}	\N	\N
16990	1591	66	f	\N	\N	2026-09-26 16:41:07.646237+07	15	auto	\N	\N	\N	{}	\N	\N
16991	1591	91	f	\N	\N	2026-09-26 16:41:07.646237+07	8	auto	\N	\N	\N	{}	\N	\N
16992	1591	57	f	\N	\N	2026-09-26 16:41:07.646237+07	9	auto	\N	\N	\N	{}	\N	\N
16993	1591	78	f	\N	\N	2026-09-26 16:41:07.646237+07	10	auto	\N	\N	\N	{}	\N	\N
16994	1591	90	f	\N	\N	2026-09-26 16:41:07.646237+07	11	auto	\N	\N	\N	{}	\N	\N
16995	1592	130	f	\N	\N	2026-09-26 16:41:07.851714+07	6	auto	\N	\N	\N	{}	\N	\N
16996	1592	94	f	\N	\N	2026-09-26 16:41:07.851714+07	7	auto	\N	\N	\N	{}	\N	\N
16997	1592	4	f	\N	\N	2026-09-26 16:41:07.851714+07	13	auto	\N	\N	\N	{}	\N	\N
16998	1592	88	f	\N	\N	2026-09-26 16:41:07.851714+07	12	auto	\N	\N	\N	{}	\N	\N
16999	1592	67	f	\N	\N	2026-09-26 16:41:07.851714+07	16	auto	\N	\N	\N	{}	\N	\N
17000	1592	69	f	\N	\N	2026-09-26 16:41:07.851714+07	17	auto	\N	\N	\N	{}	\N	\N
17001	1592	48	f	\N	\N	2026-09-26 16:41:07.851714+07	14	auto	\N	\N	\N	{}	\N	\N
17002	1592	52	f	\N	\N	2026-09-26 16:41:07.851714+07	15	auto	\N	\N	\N	{}	\N	\N
17003	1592	76	f	\N	\N	2026-09-26 16:41:07.851714+07	8	auto	\N	\N	\N	{}	\N	\N
17004	1592	70	f	\N	\N	2026-09-26 16:41:07.851714+07	9	auto	\N	\N	\N	{}	\N	\N
17005	1592	83	f	\N	\N	2026-09-26 16:41:07.851714+07	10	auto	\N	\N	\N	{}	\N	\N
17006	1592	75	f	\N	\N	2026-09-26 16:41:07.851714+07	11	auto	\N	\N	\N	{}	\N	\N
17007	1593	109	f	\N	\N	2026-09-26 16:41:07.958044+07	6	auto	\N	\N	\N	{}	\N	\N
17008	1593	106	f	\N	\N	2026-09-26 16:41:07.958044+07	7	auto	\N	\N	\N	{}	\N	\N
17009	1593	71	f	\N	\N	2026-09-26 16:41:07.958044+07	13	auto	\N	\N	\N	{}	\N	\N
17010	1593	72	f	\N	\N	2026-09-26 16:41:07.958044+07	12	auto	\N	\N	\N	{}	\N	\N
17011	1593	51	f	\N	\N	2026-09-26 16:41:07.958044+07	16	auto	\N	\N	\N	{}	\N	\N
17012	1593	47	f	\N	\N	2026-09-26 16:41:07.958044+07	17	auto	\N	\N	\N	{}	\N	\N
17013	1593	42	f	\N	\N	2026-09-26 16:41:07.958044+07	14	auto	\N	\N	\N	{}	\N	\N
17014	1593	60	f	\N	\N	2026-09-26 16:41:07.958044+07	15	auto	\N	\N	\N	{}	\N	\N
17015	1593	89	f	\N	\N	2026-09-26 16:41:07.958044+07	8	auto	\N	\N	\N	{}	\N	\N
17016	1593	12	f	\N	\N	2026-09-26 16:41:07.958044+07	9	auto	\N	\N	\N	{}	\N	\N
17017	1593	90	f	\N	\N	2026-09-26 16:41:07.958044+07	10	auto	\N	\N	\N	{}	\N	\N
17018	1593	46	f	\N	\N	2026-09-26 16:41:07.958044+07	11	auto	\N	\N	\N	{}	\N	\N
17019	1594	142	f	\N	\N	2026-09-26 16:41:08.073377+07	6	auto	\N	\N	\N	{}	\N	\N
17020	1594	103	f	\N	\N	2026-09-26 16:41:08.073377+07	7	auto	\N	\N	\N	{}	\N	\N
17021	1594	85	f	\N	\N	2026-09-26 16:41:08.073377+07	13	auto	\N	\N	\N	{}	\N	\N
17022	1594	5	f	\N	\N	2026-09-26 16:41:08.073377+07	12	auto	\N	\N	\N	{}	\N	\N
17023	1594	24	f	\N	\N	2026-09-26 16:41:08.073377+07	16	auto	\N	\N	\N	{}	\N	\N
17024	1594	53	f	\N	\N	2026-09-26 16:41:08.073377+07	17	auto	\N	\N	\N	{}	\N	\N
17025	1594	25	f	\N	\N	2026-09-26 16:41:08.073377+07	14	auto	\N	\N	\N	{}	\N	\N
17026	1594	54	f	\N	\N	2026-09-26 16:41:08.073377+07	15	auto	\N	\N	\N	{}	\N	\N
17027	1594	84	f	\N	\N	2026-09-26 16:41:08.073377+07	8	auto	\N	\N	\N	{}	\N	\N
17028	1594	58	f	\N	\N	2026-09-26 16:41:08.073377+07	9	auto	\N	\N	\N	{}	\N	\N
17029	1594	87	f	\N	\N	2026-09-26 16:41:08.073377+07	10	auto	\N	\N	\N	{}	\N	\N
17030	1594	43	f	\N	\N	2026-09-26 16:41:08.073377+07	11	auto	\N	\N	\N	{}	\N	\N
17031	1595	137	f	\N	\N	2026-09-26 16:41:08.186734+07	6	auto	\N	\N	\N	{}	\N	\N
17032	1595	127	f	\N	\N	2026-09-26 16:41:08.186734+07	7	auto	\N	\N	\N	{}	\N	\N
17033	1595	73	f	\N	\N	2026-09-26 16:41:08.186734+07	13	auto	\N	\N	\N	{}	\N	\N
17034	1595	70	f	\N	\N	2026-09-26 16:41:08.186734+07	12	auto	\N	\N	\N	{}	\N	\N
17035	1595	45	f	\N	\N	2026-09-26 16:41:08.186734+07	16	auto	\N	\N	\N	{}	\N	\N
17036	1595	57	f	\N	\N	2026-09-26 16:41:08.186734+07	17	auto	\N	\N	\N	{}	\N	\N
17037	1595	48	f	\N	\N	2026-09-26 16:41:08.186734+07	14	auto	\N	\N	\N	{}	\N	\N
17038	1595	52	f	\N	\N	2026-09-26 16:41:08.186734+07	15	auto	\N	\N	\N	{}	\N	\N
17039	1595	91	f	\N	\N	2026-09-26 16:41:08.186734+07	8	auto	\N	\N	\N	{}	\N	\N
17040	1595	61	f	\N	\N	2026-09-26 16:41:08.186734+07	9	auto	\N	\N	\N	{}	\N	\N
17041	1595	76	f	\N	\N	2026-09-26 16:41:08.186734+07	10	auto	\N	\N	\N	{}	\N	\N
17042	1595	88	f	\N	\N	2026-09-26 16:41:08.186734+07	11	auto	\N	\N	\N	{}	\N	\N
17043	1596	144	f	\N	\N	2026-09-26 16:41:08.300235+07	6	auto	\N	\N	\N	{}	\N	\N
17044	1596	101	f	\N	\N	2026-09-26 16:41:08.300235+07	7	auto	\N	\N	\N	{}	\N	\N
17045	1596	89	f	\N	\N	2026-09-26 16:41:08.300235+07	13	auto	\N	\N	\N	{}	\N	\N
17046	1596	72	f	\N	\N	2026-09-26 16:41:08.300235+07	12	auto	\N	\N	\N	{}	\N	\N
17047	1596	55	f	\N	\N	2026-09-26 16:41:08.300235+07	16	auto	\N	\N	\N	{}	\N	\N
17048	1596	41	f	\N	\N	2026-09-26 16:41:08.300235+07	17	auto	\N	\N	\N	{}	\N	\N
17049	1596	46	f	\N	\N	2026-09-26 16:41:08.300235+07	14	auto	\N	\N	\N	{}	\N	\N
17050	1596	60	f	\N	\N	2026-09-26 16:41:08.300235+07	15	auto	\N	\N	\N	{}	\N	\N
17051	1596	17	f	\N	\N	2026-09-26 16:41:08.300235+07	8	auto	\N	\N	\N	{}	\N	\N
17052	1596	42	f	\N	\N	2026-09-26 16:41:08.300235+07	9	auto	\N	\N	\N	{}	\N	\N
17053	1596	81	f	\N	\N	2026-09-26 16:41:08.300235+07	10	auto	\N	\N	\N	{}	\N	\N
17054	1596	63	f	\N	\N	2026-09-26 16:41:08.300235+07	11	auto	\N	\N	\N	{}	\N	\N
17055	1597	145	f	\N	\N	2026-09-26 16:41:08.300235+07	6	auto	\N	\N	\N	{}	\N	\N
17056	1597	97	f	\N	\N	2026-09-26 16:41:08.300235+07	7	auto	\N	\N	\N	{}	\N	\N
17057	1597	71	f	\N	\N	2026-09-26 16:41:08.300235+07	13	auto	\N	\N	\N	{}	\N	\N
17058	1597	90	f	\N	\N	2026-09-26 16:41:08.300235+07	12	auto	\N	\N	\N	{}	\N	\N
17059	1597	51	f	\N	\N	2026-09-26 16:41:08.300235+07	16	auto	\N	\N	\N	{}	\N	\N
17060	1597	65	f	\N	\N	2026-09-26 16:41:08.300235+07	17	auto	\N	\N	\N	{}	\N	\N
17061	1597	58	f	\N	\N	2026-09-26 16:41:08.300235+07	14	auto	\N	\N	\N	{}	\N	\N
17062	1597	54	f	\N	\N	2026-09-26 16:41:08.300235+07	15	auto	\N	\N	\N	{}	\N	\N
17063	1597	87	f	\N	\N	2026-09-26 16:41:08.300235+07	8	auto	\N	\N	\N	{}	\N	\N
17064	1597	53	f	\N	\N	2026-09-26 16:41:08.300235+07	9	auto	\N	\N	\N	{}	\N	\N
17065	1597	82	f	\N	\N	2026-09-26 16:41:08.300235+07	10	auto	\N	\N	\N	{}	\N	\N
17066	1597	78	f	\N	\N	2026-09-26 16:41:08.300235+07	11	auto	\N	\N	\N	{}	\N	\N
17067	1598	124	f	\N	\N	2026-09-26 16:41:08.300235+07	6	auto	\N	\N	\N	{}	\N	\N
17068	1598	119	f	\N	\N	2026-09-26 16:41:08.300235+07	7	auto	\N	\N	\N	{}	\N	\N
17069	1598	16	f	\N	\N	2026-09-26 16:41:08.300235+07	13	auto	\N	\N	\N	{}	\N	\N
17070	1598	70	f	\N	\N	2026-09-26 16:41:08.300235+07	12	auto	\N	\N	\N	{}	\N	\N
17071	1598	43	f	\N	\N	2026-09-26 16:41:08.300235+07	16	auto	\N	\N	\N	{}	\N	\N
17072	1598	49	f	\N	\N	2026-09-26 16:41:08.300235+07	17	auto	\N	\N	\N	{}	\N	\N
17073	1598	84	f	\N	\N	2026-09-26 16:41:08.300235+07	14	auto	\N	\N	\N	{}	\N	\N
17074	1598	76	f	\N	\N	2026-09-26 16:41:08.300235+07	15	auto	\N	\N	\N	{}	\N	\N
17075	1598	85	f	\N	\N	2026-09-26 16:41:08.300235+07	10	auto	\N	\N	\N	{}	\N	\N
17076	1598	91	f	\N	\N	2026-09-26 16:41:08.300235+07	11	auto	\N	\N	\N	{}	\N	\N
17077	1599	123	f	\N	\N	2026-09-26 16:41:08.548289+07	6	auto	\N	\N	\N	{}	\N	\N
17078	1599	131	f	\N	\N	2026-09-26 16:41:08.548289+07	7	auto	\N	\N	\N	{}	\N	\N
17079	1599	28	f	\N	\N	2026-09-26 16:41:08.548289+07	13	auto	\N	\N	\N	{}	\N	\N
17080	1599	29	f	\N	\N	2026-09-26 16:41:08.548289+07	12	auto	\N	\N	\N	{}	\N	\N
17081	1599	36	f	\N	\N	2026-09-26 16:41:08.548289+07	16	auto	\N	\N	\N	{}	\N	\N
17082	1599	57	f	\N	\N	2026-09-26 16:41:08.548289+07	17	auto	\N	\N	\N	{}	\N	\N
17083	1599	46	f	\N	\N	2026-09-26 16:41:08.548289+07	14	auto	\N	\N	\N	{}	\N	\N
17084	1599	42	f	\N	\N	2026-09-26 16:41:08.548289+07	15	auto	\N	\N	\N	{}	\N	\N
17085	1599	73	f	\N	\N	2026-09-26 16:41:08.548289+07	8	auto	\N	\N	\N	{}	\N	\N
17086	1599	61	f	\N	\N	2026-09-26 16:41:08.548289+07	9	auto	\N	\N	\N	{}	\N	\N
17087	1599	72	f	\N	\N	2026-09-26 16:41:08.548289+07	10	auto	\N	\N	\N	{}	\N	\N
17088	1599	82	f	\N	\N	2026-09-26 16:41:08.548289+07	11	auto	\N	\N	\N	{}	\N	\N
17089	1600	139	f	\N	\N	2026-09-26 16:41:08.668545+07	6	auto	\N	\N	\N	{}	\N	\N
17090	1600	126	f	\N	\N	2026-09-26 16:41:08.668545+07	7	auto	\N	\N	\N	{}	\N	\N
17091	1600	75	f	\N	\N	2026-09-26 16:41:08.668545+07	13	auto	\N	\N	\N	{}	\N	\N
17092	1600	78	f	\N	\N	2026-09-26 16:41:08.668545+07	12	auto	\N	\N	\N	{}	\N	\N
17093	1600	45	f	\N	\N	2026-09-26 16:41:08.668545+07	16	auto	\N	\N	\N	{}	\N	\N
17094	1600	47	f	\N	\N	2026-09-26 16:41:08.668545+07	17	auto	\N	\N	\N	{}	\N	\N
17095	1600	48	f	\N	\N	2026-09-26 16:41:08.668545+07	14	auto	\N	\N	\N	{}	\N	\N
17096	1600	64	f	\N	\N	2026-09-26 16:41:08.668545+07	15	auto	\N	\N	\N	{}	\N	\N
17097	1600	84	f	\N	\N	2026-09-26 16:41:08.668545+07	8	auto	\N	\N	\N	{}	\N	\N
17098	1600	66	f	\N	\N	2026-09-26 16:41:08.668545+07	9	auto	\N	\N	\N	{}	\N	\N
17099	1600	89	f	\N	\N	2026-09-26 16:41:08.668545+07	10	auto	\N	\N	\N	{}	\N	\N
17100	1600	12	f	\N	\N	2026-09-26 16:41:08.668545+07	11	auto	\N	\N	\N	{}	\N	\N
17101	1601	132	f	\N	\N	2026-09-26 16:41:08.77832+07	6	auto	\N	\N	\N	{}	\N	\N
17102	1601	125	f	\N	\N	2026-09-26 16:41:08.77832+07	7	auto	\N	\N	\N	{}	\N	\N
17103	1601	4	f	\N	\N	2026-09-26 16:41:08.77832+07	13	auto	\N	\N	\N	{}	\N	\N
17104	1601	88	f	\N	\N	2026-09-26 16:41:08.77832+07	12	auto	\N	\N	\N	{}	\N	\N
17105	1601	63	f	\N	\N	2026-09-26 16:41:08.77832+07	16	auto	\N	\N	\N	{}	\N	\N
17106	1601	55	f	\N	\N	2026-09-26 16:41:08.77832+07	17	auto	\N	\N	\N	{}	\N	\N
17107	1601	37	f	\N	\N	2026-09-26 16:41:08.77832+07	14	auto	\N	\N	\N	{}	\N	\N
17108	1601	52	f	\N	\N	2026-09-26 16:41:08.77832+07	15	auto	\N	\N	\N	{}	\N	\N
17109	1601	81	f	\N	\N	2026-09-26 16:41:08.77832+07	8	auto	\N	\N	\N	{}	\N	\N
17110	1601	41	f	\N	\N	2026-09-26 16:41:08.77832+07	9	auto	\N	\N	\N	{}	\N	\N
17111	1601	72	f	\N	\N	2026-09-26 16:41:08.77832+07	10	auto	\N	\N	\N	{}	\N	\N
17112	1601	82	f	\N	\N	2026-09-26 16:41:08.77832+07	11	auto	\N	\N	\N	{}	\N	\N
17113	1602	133	f	\N	\N	2026-09-26 16:41:08.897063+07	6	auto	\N	\N	\N	{}	\N	\N
17114	1602	111	f	\N	\N	2026-09-26 16:41:08.897063+07	7	auto	\N	\N	\N	{}	\N	\N
17115	1602	87	f	\N	\N	2026-09-26 16:41:08.897063+07	13	auto	\N	\N	\N	{}	\N	\N
17116	1602	78	f	\N	\N	2026-09-26 16:41:08.897063+07	12	auto	\N	\N	\N	{}	\N	\N
17117	1602	65	f	\N	\N	2026-09-26 16:41:08.897063+07	16	auto	\N	\N	\N	{}	\N	\N
17118	1602	69	f	\N	\N	2026-09-26 16:41:08.897063+07	17	auto	\N	\N	\N	{}	\N	\N
17119	1602	66	f	\N	\N	2026-09-26 16:41:08.897063+07	14	auto	\N	\N	\N	{}	\N	\N
17120	1602	48	f	\N	\N	2026-09-26 16:41:08.897063+07	15	auto	\N	\N	\N	{}	\N	\N
17121	1602	84	f	\N	\N	2026-09-26 16:41:08.897063+07	8	auto	\N	\N	\N	{}	\N	\N
17122	1602	64	f	\N	\N	2026-09-26 16:41:08.897063+07	9	auto	\N	\N	\N	{}	\N	\N
17123	1602	16	f	\N	\N	2026-09-26 16:41:08.897063+07	10	auto	\N	\N	\N	{}	\N	\N
17124	1602	49	f	\N	\N	2026-09-26 16:41:08.897063+07	11	auto	\N	\N	\N	{}	\N	\N
17125	1603	148	f	\N	\N	2026-09-26 16:41:09.014745+07	6	auto	\N	\N	\N	{}	\N	\N
17126	1603	108	f	\N	\N	2026-09-26 16:41:09.014745+07	7	auto	\N	\N	\N	{}	\N	\N
17127	1603	91	f	\N	\N	2026-09-26 16:41:09.014745+07	13	auto	\N	\N	\N	{}	\N	\N
17128	1603	88	f	\N	\N	2026-09-26 16:41:09.014745+07	12	auto	\N	\N	\N	{}	\N	\N
17129	1603	67	f	\N	\N	2026-09-26 16:41:09.014745+07	16	auto	\N	\N	\N	{}	\N	\N
17130	1603	57	f	\N	\N	2026-09-26 16:41:09.014745+07	17	auto	\N	\N	\N	{}	\N	\N
17131	1603	54	f	\N	\N	2026-09-26 16:41:09.014745+07	14	auto	\N	\N	\N	{}	\N	\N
17132	1603	37	f	\N	\N	2026-09-26 16:41:09.014745+07	15	auto	\N	\N	\N	{}	\N	\N
17133	1603	77	f	\N	\N	2026-09-26 16:41:09.014745+07	8	auto	\N	\N	\N	{}	\N	\N
17134	1603	51	f	\N	\N	2026-09-26 16:41:09.014745+07	9	auto	\N	\N	\N	{}	\N	\N
17135	1603	72	f	\N	\N	2026-09-26 16:41:09.014745+07	10	auto	\N	\N	\N	{}	\N	\N
17136	1603	90	f	\N	\N	2026-09-26 16:41:09.014745+07	11	auto	\N	\N	\N	{}	\N	\N
17137	1604	136	f	\N	\N	2026-09-26 16:41:09.014745+07	6	auto	\N	\N	\N	{}	\N	\N
17138	1604	99	f	\N	\N	2026-09-26 16:41:09.014745+07	7	auto	\N	\N	\N	{}	\N	\N
17139	1604	83	f	\N	\N	2026-09-26 16:41:09.014745+07	13	auto	\N	\N	\N	{}	\N	\N
17140	1604	82	f	\N	\N	2026-09-26 16:41:09.014745+07	12	auto	\N	\N	\N	{}	\N	\N
17141	1604	53	f	\N	\N	2026-09-26 16:41:09.014745+07	16	auto	\N	\N	\N	{}	\N	\N
17142	1604	61	f	\N	\N	2026-09-26 16:41:09.014745+07	17	auto	\N	\N	\N	{}	\N	\N
17143	1604	52	f	\N	\N	2026-09-26 16:41:09.014745+07	14	auto	\N	\N	\N	{}	\N	\N
17144	1604	48	f	\N	\N	2026-09-26 16:41:09.014745+07	15	auto	\N	\N	\N	{}	\N	\N
17145	1604	76	f	\N	\N	2026-09-26 16:41:09.014745+07	8	auto	\N	\N	\N	{}	\N	\N
17146	1604	46	f	\N	\N	2026-09-26 16:41:09.014745+07	9	auto	\N	\N	\N	{}	\N	\N
17147	1604	73	f	\N	\N	2026-09-26 16:41:09.014745+07	10	auto	\N	\N	\N	{}	\N	\N
17148	1604	12	f	\N	\N	2026-09-26 16:41:09.014745+07	11	auto	\N	\N	\N	{}	\N	\N
17149	1605	135	f	\N	\N	2026-09-26 16:41:09.014745+07	6	auto	\N	\N	\N	{}	\N	\N
17150	1605	96	f	\N	\N	2026-09-26 16:41:09.014745+07	7	auto	\N	\N	\N	{}	\N	\N
17151	1605	75	f	\N	\N	2026-09-26 16:41:09.014745+07	13	auto	\N	\N	\N	{}	\N	\N
17152	1605	78	f	\N	\N	2026-09-26 16:41:09.014745+07	12	auto	\N	\N	\N	{}	\N	\N
17153	1605	47	f	\N	\N	2026-09-26 16:41:09.014745+07	16	auto	\N	\N	\N	{}	\N	\N
17154	1605	63	f	\N	\N	2026-09-26 16:41:09.014745+07	17	auto	\N	\N	\N	{}	\N	\N
17155	1605	66	f	\N	\N	2026-09-26 16:41:09.014745+07	14	auto	\N	\N	\N	{}	\N	\N
17156	1605	64	f	\N	\N	2026-09-26 16:41:09.014745+07	15	auto	\N	\N	\N	{}	\N	\N
17157	1605	81	f	\N	\N	2026-09-26 16:41:09.014745+07	8	auto	\N	\N	\N	{}	\N	\N
17158	1605	71	f	\N	\N	2026-09-26 16:41:09.014745+07	9	auto	\N	\N	\N	{}	\N	\N
17159	1605	84	f	\N	\N	2026-09-26 16:41:09.014745+07	10	auto	\N	\N	\N	{}	\N	\N
17160	1605	58	f	\N	\N	2026-09-26 16:41:09.014745+07	11	auto	\N	\N	\N	{}	\N	\N
17161	1606	139	f	\N	\N	2026-09-26 16:41:09.23612+07	6	auto	\N	\N	\N	{}	\N	\N
17162	1606	8	f	\N	\N	2026-09-26 16:41:09.23612+07	7	auto	\N	\N	\N	{}	\N	\N
17163	1606	85	f	\N	\N	2026-09-26 16:41:09.23612+07	13	auto	\N	\N	\N	{}	\N	\N
17164	1606	17	f	\N	\N	2026-09-26 16:41:09.23612+07	12	auto	\N	\N	\N	{}	\N	\N
17165	1606	24	f	\N	\N	2026-09-26 16:41:09.23612+07	16	auto	\N	\N	\N	{}	\N	\N
17166	1606	49	f	\N	\N	2026-09-26 16:41:09.23612+07	17	auto	\N	\N	\N	{}	\N	\N
17167	1606	25	f	\N	\N	2026-09-26 16:41:09.23612+07	14	auto	\N	\N	\N	{}	\N	\N
17168	1606	60	f	\N	\N	2026-09-26 16:41:09.23612+07	15	auto	\N	\N	\N	{}	\N	\N
17169	1606	90	f	\N	\N	2026-09-26 16:41:09.23612+07	8	auto	\N	\N	\N	{}	\N	\N
17170	1606	88	f	\N	\N	2026-09-26 16:41:09.23612+07	9	auto	\N	\N	\N	{}	\N	\N
17171	1606	77	f	\N	\N	2026-09-26 16:41:09.23612+07	10	auto	\N	\N	\N	{}	\N	\N
17172	1606	65	f	\N	\N	2026-09-26 16:41:09.23612+07	11	auto	\N	\N	\N	{}	\N	\N
17173	1607	149	f	\N	\N	2026-09-26 16:41:09.356809+07	6	auto	\N	\N	\N	{}	\N	\N
17174	1607	95	f	\N	\N	2026-09-26 16:41:09.356809+07	7	auto	\N	\N	\N	{}	\N	\N
17175	1607	83	f	\N	\N	2026-09-26 16:41:09.356809+07	13	auto	\N	\N	\N	{}	\N	\N
17176	1607	76	f	\N	\N	2026-09-26 16:41:09.356809+07	12	auto	\N	\N	\N	{}	\N	\N
17177	1607	43	f	\N	\N	2026-09-26 16:41:09.356809+07	16	auto	\N	\N	\N	{}	\N	\N
17178	1607	45	f	\N	\N	2026-09-26 16:41:09.356809+07	17	auto	\N	\N	\N	{}	\N	\N
17179	1607	42	f	\N	\N	2026-09-26 16:41:09.356809+07	14	auto	\N	\N	\N	{}	\N	\N
17180	1607	54	f	\N	\N	2026-09-26 16:41:09.356809+07	15	auto	\N	\N	\N	{}	\N	\N
17181	1607	70	f	\N	\N	2026-09-26 16:41:09.356809+07	8	auto	\N	\N	\N	{}	\N	\N
17182	1607	69	f	\N	\N	2026-09-26 16:41:09.356809+07	9	auto	\N	\N	\N	{}	\N	\N
17183	1607	82	f	\N	\N	2026-09-26 16:41:09.356809+07	10	auto	\N	\N	\N	{}	\N	\N
17184	1607	46	f	\N	\N	2026-09-26 16:41:09.356809+07	11	auto	\N	\N	\N	{}	\N	\N
17185	1608	117	f	\N	\N	2026-09-26 16:41:09.47843+07	6	auto	\N	\N	\N	{}	\N	\N
17186	1608	130	f	\N	\N	2026-09-26 16:41:09.47843+07	7	auto	\N	\N	\N	{}	\N	\N
17187	1608	28	f	\N	\N	2026-09-26 16:41:09.47843+07	13	auto	\N	\N	\N	{}	\N	\N
17188	1608	29	f	\N	\N	2026-09-26 16:41:09.47843+07	12	auto	\N	\N	\N	{}	\N	\N
17189	1608	51	f	\N	\N	2026-09-26 16:41:09.47843+07	16	auto	\N	\N	\N	{}	\N	\N
17190	1608	67	f	\N	\N	2026-09-26 16:41:09.47843+07	17	auto	\N	\N	\N	{}	\N	\N
17191	1608	52	f	\N	\N	2026-09-26 16:41:09.47843+07	14	auto	\N	\N	\N	{}	\N	\N
17192	1608	48	f	\N	\N	2026-09-26 16:41:09.47843+07	15	auto	\N	\N	\N	{}	\N	\N
17193	1608	5	f	\N	\N	2026-09-26 16:41:09.47843+07	8	auto	\N	\N	\N	{}	\N	\N
17194	1608	66	f	\N	\N	2026-09-26 16:41:09.47843+07	9	auto	\N	\N	\N	{}	\N	\N
17195	1608	75	f	\N	\N	2026-09-26 16:41:09.47843+07	10	auto	\N	\N	\N	{}	\N	\N
17196	1608	53	f	\N	\N	2026-09-26 16:41:09.47843+07	11	auto	\N	\N	\N	{}	\N	\N
17197	1609	145	f	\N	\N	2026-09-26 16:41:09.602216+07	6	auto	\N	\N	\N	{}	\N	\N
17198	1609	106	f	\N	\N	2026-09-26 16:41:09.602216+07	7	auto	\N	\N	\N	{}	\N	\N
17199	1609	4	f	\N	\N	2026-09-26 16:41:09.602216+07	13	auto	\N	\N	\N	{}	\N	\N
17200	1609	17	f	\N	\N	2026-09-26 16:41:09.602216+07	12	auto	\N	\N	\N	{}	\N	\N
17201	1609	41	f	\N	\N	2026-09-26 16:41:09.602216+07	16	auto	\N	\N	\N	{}	\N	\N
17202	1609	47	f	\N	\N	2026-09-26 16:41:09.602216+07	17	auto	\N	\N	\N	{}	\N	\N
17203	1609	58	f	\N	\N	2026-09-26 16:41:09.602216+07	14	auto	\N	\N	\N	{}	\N	\N
17204	1609	64	f	\N	\N	2026-09-26 16:41:09.602216+07	15	auto	\N	\N	\N	{}	\N	\N
17205	1609	85	f	\N	\N	2026-09-26 16:41:09.602216+07	8	auto	\N	\N	\N	{}	\N	\N
17206	1609	49	f	\N	\N	2026-09-26 16:41:09.602216+07	9	auto	\N	\N	\N	{}	\N	\N
17207	1609	90	f	\N	\N	2026-09-26 16:41:09.602216+07	10	auto	\N	\N	\N	{}	\N	\N
17208	1609	60	f	\N	\N	2026-09-26 16:41:09.602216+07	11	auto	\N	\N	\N	{}	\N	\N
17209	1610	22	f	\N	\N	2026-09-26 16:41:09.725591+07	6	auto	\N	\N	\N	{}	\N	\N
17210	1610	103	f	\N	\N	2026-09-26 16:41:09.725591+07	7	auto	\N	\N	\N	{}	\N	\N
17211	1610	77	f	\N	\N	2026-09-26 16:41:09.725591+07	13	auto	\N	\N	\N	{}	\N	\N
17212	1610	88	f	\N	\N	2026-09-26 16:41:09.725591+07	12	auto	\N	\N	\N	{}	\N	\N
17213	1610	63	f	\N	\N	2026-09-26 16:41:09.725591+07	16	auto	\N	\N	\N	{}	\N	\N
17214	1610	69	f	\N	\N	2026-09-26 16:41:09.725591+07	17	auto	\N	\N	\N	{}	\N	\N
17215	1610	54	f	\N	\N	2026-09-26 16:41:09.725591+07	14	auto	\N	\N	\N	{}	\N	\N
17216	1610	42	f	\N	\N	2026-09-26 16:41:09.725591+07	15	auto	\N	\N	\N	{}	\N	\N
17217	1610	76	f	\N	\N	2026-09-26 16:41:09.725591+07	8	auto	\N	\N	\N	{}	\N	\N
17218	1610	70	f	\N	\N	2026-09-26 16:41:09.725591+07	9	auto	\N	\N	\N	{}	\N	\N
17219	1610	71	f	\N	\N	2026-09-26 16:41:09.725591+07	10	auto	\N	\N	\N	{}	\N	\N
17220	1610	43	f	\N	\N	2026-09-26 16:41:09.725591+07	11	auto	\N	\N	\N	{}	\N	\N
17221	1611	138	f	\N	\N	2026-09-26 16:41:09.725591+07	6	auto	\N	\N	\N	{}	\N	\N
17222	1611	94	f	\N	\N	2026-09-26 16:41:09.725591+07	7	auto	\N	\N	\N	{}	\N	\N
17223	1611	83	f	\N	\N	2026-09-26 16:41:09.725591+07	13	auto	\N	\N	\N	{}	\N	\N
17224	1611	5	f	\N	\N	2026-09-26 16:41:09.725591+07	12	auto	\N	\N	\N	{}	\N	\N
17225	1611	45	f	\N	\N	2026-09-26 16:41:09.725591+07	16	auto	\N	\N	\N	{}	\N	\N
17226	1611	55	f	\N	\N	2026-09-26 16:41:09.725591+07	17	auto	\N	\N	\N	{}	\N	\N
17227	1611	46	f	\N	\N	2026-09-26 16:41:09.725591+07	14	auto	\N	\N	\N	{}	\N	\N
17228	1611	52	f	\N	\N	2026-09-26 16:41:09.725591+07	15	auto	\N	\N	\N	{}	\N	\N
17229	1611	28	f	\N	\N	2026-09-26 16:41:09.725591+07	8	auto	\N	\N	\N	{}	\N	\N
17230	1611	89	f	\N	\N	2026-09-26 16:41:09.725591+07	9	auto	\N	\N	\N	{}	\N	\N
17231	1611	84	f	\N	\N	2026-09-26 16:41:09.725591+07	10	auto	\N	\N	\N	{}	\N	\N
17232	1611	29	f	\N	\N	2026-09-26 16:41:09.725591+07	11	auto	\N	\N	\N	{}	\N	\N
17233	1612	145	f	\N	\N	2026-09-26 16:41:09.725591+07	6	auto	\N	\N	\N	{}	\N	\N
17234	1612	119	f	\N	\N	2026-09-26 16:41:09.725591+07	7	auto	\N	\N	\N	{}	\N	\N
17235	1612	87	f	\N	\N	2026-09-26 16:41:09.725591+07	13	auto	\N	\N	\N	{}	\N	\N
17236	1612	90	f	\N	\N	2026-09-26 16:41:09.725591+07	12	auto	\N	\N	\N	{}	\N	\N
17237	1612	67	f	\N	\N	2026-09-26 16:41:09.725591+07	16	auto	\N	\N	\N	{}	\N	\N
17238	1612	51	f	\N	\N	2026-09-26 16:41:09.725591+07	17	auto	\N	\N	\N	{}	\N	\N
17239	1612	58	f	\N	\N	2026-09-26 16:41:09.725591+07	14	auto	\N	\N	\N	{}	\N	\N
17240	1612	60	f	\N	\N	2026-09-26 16:41:09.725591+07	15	auto	\N	\N	\N	{}	\N	\N
17241	1612	85	f	\N	\N	2026-09-26 16:41:09.725591+07	10	auto	\N	\N	\N	{}	\N	\N
17242	1612	53	f	\N	\N	2026-09-26 16:41:09.725591+07	11	auto	\N	\N	\N	{}	\N	\N
17243	1613	124	f	\N	\N	2026-09-26 16:41:09.951847+07	6	auto	\N	\N	\N	{}	\N	\N
17244	1613	127	f	\N	\N	2026-09-26 16:41:09.951847+07	7	auto	\N	\N	\N	{}	\N	\N
17245	1613	16	f	\N	\N	2026-09-26 16:41:09.951847+07	13	auto	\N	\N	\N	{}	\N	\N
17246	1613	70	f	\N	\N	2026-09-26 16:41:09.951847+07	12	auto	\N	\N	\N	{}	\N	\N
17247	1613	65	f	\N	\N	2026-09-26 16:41:09.951847+07	16	auto	\N	\N	\N	{}	\N	\N
17248	1613	57	f	\N	\N	2026-09-26 16:41:09.951847+07	17	auto	\N	\N	\N	{}	\N	\N
17249	1613	37	f	\N	\N	2026-09-26 16:41:09.951847+07	14	auto	\N	\N	\N	{}	\N	\N
17250	1613	54	f	\N	\N	2026-09-26 16:41:09.951847+07	15	auto	\N	\N	\N	{}	\N	\N
17251	1613	4	f	\N	\N	2026-09-26 16:41:09.951847+07	8	auto	\N	\N	\N	{}	\N	\N
17252	1613	41	f	\N	\N	2026-09-26 16:41:09.951847+07	9	auto	\N	\N	\N	{}	\N	\N
17253	1613	88	f	\N	\N	2026-09-26 16:41:09.951847+07	10	auto	\N	\N	\N	{}	\N	\N
17254	1613	42	f	\N	\N	2026-09-26 16:41:09.951847+07	11	auto	\N	\N	\N	{}	\N	\N
17255	1614	144	f	\N	\N	2026-09-26 16:41:10.077238+07	6	auto	\N	\N	\N	{}	\N	\N
17256	1614	101	f	\N	\N	2026-09-26 16:41:10.077238+07	7	auto	\N	\N	\N	{}	\N	\N
17257	1614	91	f	\N	\N	2026-09-26 16:41:10.077238+07	13	auto	\N	\N	\N	{}	\N	\N
17258	1614	78	f	\N	\N	2026-09-26 16:41:10.077238+07	12	auto	\N	\N	\N	{}	\N	\N
17259	1614	12	f	\N	\N	2026-09-26 16:41:10.077238+07	16	auto	\N	\N	\N	{}	\N	\N
17260	1614	43	f	\N	\N	2026-09-26 16:41:10.077238+07	17	auto	\N	\N	\N	{}	\N	\N
17261	1614	46	f	\N	\N	2026-09-26 16:41:10.077238+07	14	auto	\N	\N	\N	{}	\N	\N
17262	1614	58	f	\N	\N	2026-09-26 16:41:10.077238+07	15	auto	\N	\N	\N	{}	\N	\N
17263	1614	82	f	\N	\N	2026-09-26 16:41:10.077238+07	8	auto	\N	\N	\N	{}	\N	\N
17264	1614	76	f	\N	\N	2026-09-26 16:41:10.077238+07	9	auto	\N	\N	\N	{}	\N	\N
17265	1614	71	f	\N	\N	2026-09-26 16:41:10.077238+07	10	auto	\N	\N	\N	{}	\N	\N
17266	1614	61	f	\N	\N	2026-09-26 16:41:10.077238+07	11	auto	\N	\N	\N	{}	\N	\N
17267	1615	139	f	\N	\N	2026-09-26 16:41:10.196619+07	6	auto	\N	\N	\N	{}	\N	\N
17268	1615	105	f	\N	\N	2026-09-26 16:41:10.196619+07	7	auto	\N	\N	\N	{}	\N	\N
17269	1615	83	f	\N	\N	2026-09-26 16:41:10.196619+07	13	auto	\N	\N	\N	{}	\N	\N
17270	1615	5	f	\N	\N	2026-09-26 16:41:10.196619+07	12	auto	\N	\N	\N	{}	\N	\N
17271	1615	24	f	\N	\N	2026-09-26 16:41:10.196619+07	16	auto	\N	\N	\N	{}	\N	\N
17272	1615	55	f	\N	\N	2026-09-26 16:41:10.196619+07	17	auto	\N	\N	\N	{}	\N	\N
17273	1615	25	f	\N	\N	2026-09-26 16:41:10.196619+07	14	auto	\N	\N	\N	{}	\N	\N
17274	1615	48	f	\N	\N	2026-09-26 16:41:10.196619+07	15	auto	\N	\N	\N	{}	\N	\N
17275	1615	89	f	\N	\N	2026-09-26 16:41:10.196619+07	8	auto	\N	\N	\N	{}	\N	\N
17276	1615	45	f	\N	\N	2026-09-26 16:41:10.196619+07	9	auto	\N	\N	\N	{}	\N	\N
17277	1615	72	f	\N	\N	2026-09-26 16:41:10.196619+07	10	auto	\N	\N	\N	{}	\N	\N
17278	1615	17	f	\N	\N	2026-09-26 16:41:10.196619+07	11	auto	\N	\N	\N	{}	\N	\N
17279	1616	132	f	\N	\N	2026-09-26 16:41:10.324459+07	6	auto	\N	\N	\N	{}	\N	\N
17280	1616	97	f	\N	\N	2026-09-26 16:41:10.324459+07	7	auto	\N	\N	\N	{}	\N	\N
17281	1616	73	f	\N	\N	2026-09-26 16:41:10.324459+07	13	auto	\N	\N	\N	{}	\N	\N
17282	1616	90	f	\N	\N	2026-09-26 16:41:10.324459+07	12	auto	\N	\N	\N	{}	\N	\N
17283	1616	41	f	\N	\N	2026-09-26 16:41:10.324459+07	16	auto	\N	\N	\N	{}	\N	\N
17284	1616	57	f	\N	\N	2026-09-26 16:41:10.324459+07	17	auto	\N	\N	\N	{}	\N	\N
17285	1616	60	f	\N	\N	2026-09-26 16:41:10.324459+07	14	auto	\N	\N	\N	{}	\N	\N
17286	1616	66	f	\N	\N	2026-09-26 16:41:10.324459+07	15	auto	\N	\N	\N	{}	\N	\N
17287	1616	88	f	\N	\N	2026-09-26 16:41:10.324459+07	8	auto	\N	\N	\N	{}	\N	\N
17288	1616	54	f	\N	\N	2026-09-26 16:41:10.324459+07	9	auto	\N	\N	\N	{}	\N	\N
17289	1616	75	f	\N	\N	2026-09-26 16:41:10.324459+07	10	auto	\N	\N	\N	{}	\N	\N
17290	1616	81	f	\N	\N	2026-09-26 16:41:10.324459+07	11	auto	\N	\N	\N	{}	\N	\N
17291	1617	153	f	\N	\N	2026-09-26 16:45:58.757826+07	33	auto	\N	\N	\N	{}	\N	\N
17292	1618	154	f	\N	\N	2026-09-26 16:45:58.870796+07	33	auto	\N	\N	\N	{}	\N	\N
17293	1619	155	f	\N	\N	2026-09-26 16:45:58.870796+07	33	auto	\N	\N	\N	{}	\N	\N
17294	1620	156	f	\N	\N	2026-09-26 16:45:59.014572+07	33	auto	\N	\N	\N	{}	\N	\N
17295	1621	157	f	\N	\N	2026-09-26 16:45:59.130721+07	33	auto	\N	\N	\N	{}	\N	\N
17296	1622	158	f	\N	\N	2026-09-26 16:45:59.130721+07	33	auto	\N	\N	\N	{}	\N	\N
17297	1623	159	f	\N	\N	2026-09-26 16:45:59.130721+07	33	auto	\N	\N	\N	{}	\N	\N
17298	1624	160	f	\N	\N	2026-09-26 16:45:59.30354+07	33	auto	\N	\N	\N	{}	\N	\N
17299	1625	161	f	\N	\N	2026-09-26 16:45:59.399643+07	33	auto	\N	\N	\N	{}	\N	\N
17300	1626	162	f	\N	\N	2026-09-26 16:45:59.497463+07	33	auto	\N	\N	\N	{}	\N	\N
17301	1627	163	f	\N	\N	2026-09-26 16:45:59.611549+07	33	auto	\N	\N	\N	{}	\N	\N
17302	1628	164	f	\N	\N	2026-09-26 16:45:59.709501+07	33	auto	\N	\N	\N	{}	\N	\N
17303	1629	165	f	\N	\N	2026-09-26 16:45:59.709501+07	33	auto	\N	\N	\N	{}	\N	\N
17304	1630	166	f	\N	\N	2026-09-26 16:45:59.709501+07	33	auto	\N	\N	\N	{}	\N	\N
17305	1631	167	f	\N	\N	2026-09-26 16:45:59.880101+07	33	auto	\N	\N	\N	{}	\N	\N
17306	1632	168	f	\N	\N	2026-09-26 16:45:59.984671+07	33	auto	\N	\N	\N	{}	\N	\N
17307	1633	169	f	\N	\N	2026-09-26 16:46:00.084805+07	33	auto	\N	\N	\N	{}	\N	\N
17308	1634	170	f	\N	\N	2026-09-26 16:46:00.183285+07	33	auto	\N	\N	\N	{}	\N	\N
17309	1635	23	f	\N	\N	2026-09-26 16:46:00.281816+07	33	auto	\N	\N	\N	{}	\N	\N
17310	1636	33	f	\N	\N	2026-09-26 16:46:00.281816+07	33	auto	\N	\N	\N	{}	\N	\N
17311	1637	110	f	\N	\N	2026-09-26 16:46:00.281816+07	33	auto	\N	\N	\N	{}	\N	\N
17312	1638	116	f	\N	\N	2026-09-26 16:46:00.458233+07	33	auto	\N	\N	\N	{}	\N	\N
17313	1639	120	f	\N	\N	2026-09-26 16:46:00.557391+07	33	auto	\N	\N	\N	{}	\N	\N
17314	1640	122	f	\N	\N	2026-09-26 16:46:00.657293+07	33	auto	\N	\N	\N	{}	\N	\N
17315	1641	128	f	\N	\N	2026-09-26 16:46:00.761782+07	33	auto	\N	\N	\N	{}	\N	\N
17316	1642	134	f	\N	\N	2026-09-26 16:46:00.861661+07	33	auto	\N	\N	\N	{}	\N	\N
17317	1643	140	f	\N	\N	2026-09-26 16:46:00.861661+07	33	auto	\N	\N	\N	{}	\N	\N
17318	1644	146	f	\N	\N	2026-09-26 16:46:00.861661+07	33	auto	\N	\N	\N	{}	\N	\N
5805	601	111	f	\N	\N	2026-09-19 14:50:53.890885+07	6	auto	\N	\N	\N	{}	\N	\N
5806	601	112	f	\N	\N	2026-09-19 14:50:53.890885+07	7	auto	\N	\N	\N	{}	\N	\N
5807	601	89	f	\N	\N	2026-09-19 14:50:53.890885+07	13	auto	\N	\N	\N	{}	\N	\N
5808	601	76	f	\N	\N	2026-09-19 14:50:53.890885+07	12	auto	\N	\N	\N	{}	\N	\N
5809	601	24	f	\N	\N	2026-09-19 14:50:53.890885+07	16	auto	\N	\N	\N	{}	\N	\N
5810	601	41	f	\N	\N	2026-09-19 14:50:53.890885+07	17	auto	\N	\N	\N	{}	\N	\N
5811	601	37	f	\N	\N	2026-09-19 14:50:53.890885+07	14	auto	\N	\N	\N	{}	\N	\N
5812	601	42	f	\N	\N	2026-09-19 14:50:53.890885+07	15	auto	\N	\N	\N	{}	\N	\N
5813	601	88	f	\N	\N	2026-09-19 14:50:53.890885+07	8	auto	\N	\N	\N	{}	\N	\N
5814	601	66	f	\N	\N	2026-09-19 14:50:53.890885+07	9	auto	\N	\N	\N	{}	\N	\N
5815	601	91	f	\N	\N	2026-09-19 14:50:53.890885+07	10	auto	\N	\N	\N	{}	\N	\N
5816	601	16	f	\N	\N	2026-09-19 14:50:53.890885+07	11	auto	\N	\N	\N	{}	\N	\N
5781	599	34	f	\N	\N	2026-09-19 14:50:53.623866+07	6	auto	\N	\N	\N	{}	\N	\N
5782	599	108	f	\N	\N	2026-09-19 14:50:53.623866+07	7	auto	\N	\N	\N	{}	\N	\N
5783	599	85	f	\N	\N	2026-09-19 14:50:53.623866+07	13	auto	\N	\N	\N	{}	\N	\N
5784	599	90	f	\N	\N	2026-09-19 14:50:53.623866+07	12	auto	\N	\N	\N	{}	\N	\N
5785	599	65	f	\N	\N	2026-09-19 14:50:53.623866+07	16	auto	\N	\N	\N	{}	\N	\N
5786	599	67	f	\N	\N	2026-09-19 14:50:53.623866+07	17	auto	\N	\N	\N	{}	\N	\N
5787	599	54	f	\N	\N	2026-09-19 14:50:53.623866+07	14	auto	\N	\N	\N	{}	\N	\N
5788	599	60	f	\N	\N	2026-09-19 14:50:53.623866+07	15	auto	\N	\N	\N	{}	\N	\N
5789	599	17	f	\N	\N	2026-09-19 14:50:53.623866+07	8	auto	\N	\N	\N	{}	\N	\N
5790	599	70	f	\N	\N	2026-09-19 14:50:53.623866+07	9	auto	\N	\N	\N	{}	\N	\N
5791	599	81	f	\N	\N	2026-09-19 14:50:53.623866+07	10	auto	\N	\N	\N	{}	\N	\N
5792	599	36	f	\N	\N	2026-09-19 14:50:53.623866+07	11	auto	\N	\N	\N	{}	\N	\N
5793	600	35	f	\N	\N	2026-09-19 14:50:53.756938+07	6	auto	\N	\N	\N	{}	\N	\N
5794	600	109	f	\N	\N	2026-09-19 14:50:53.756938+07	7	auto	\N	\N	\N	{}	\N	\N
5795	600	87	f	\N	\N	2026-09-19 14:50:53.756938+07	13	auto	\N	\N	\N	{}	\N	\N
5796	600	72	f	\N	\N	2026-09-19 14:50:53.756938+07	12	auto	\N	\N	\N	{}	\N	\N
5797	600	49	f	\N	\N	2026-09-19 14:50:53.756938+07	16	auto	\N	\N	\N	{}	\N	\N
5798	600	69	f	\N	\N	2026-09-19 14:50:53.756938+07	17	auto	\N	\N	\N	{}	\N	\N
5799	600	58	f	\N	\N	2026-09-19 14:50:53.756938+07	14	auto	\N	\N	\N	{}	\N	\N
5800	600	52	f	\N	\N	2026-09-19 14:50:53.756938+07	15	auto	\N	\N	\N	{}	\N	\N
5801	600	4	f	\N	\N	2026-09-19 14:50:53.756938+07	8	auto	\N	\N	\N	{}	\N	\N
5802	600	12	f	\N	\N	2026-09-19 14:50:53.756938+07	9	auto	\N	\N	\N	{}	\N	\N
5803	600	84	f	\N	\N	2026-09-19 14:50:53.756938+07	10	auto	\N	\N	\N	{}	\N	\N
5804	600	64	f	\N	\N	2026-09-19 14:50:53.756938+07	11	auto	\N	\N	\N	{}	\N	\N
6522	410	95	f	\N	\N	2026-09-19 14:52:08.23134+07	4	auto	\N	\N	\N	{}	\N	\N
6523	348	39	f	\N	\N	2026-09-19 14:52:08.382546+07	29	auto	\N	\N	\N	{}	\N	\N
6524	348	95	f	\N	\N	2026-09-19 14:52:08.382546+07	30	auto	\N	\N	\N	{}	\N	\N
6525	348	75	f	\N	\N	2026-09-19 14:52:08.382546+07	28	auto	\N	\N	\N	{}	2026-09-22	\N
6526	348	81	f	\N	\N	2026-09-19 14:52:08.382546+07	27	auto	\N	\N	\N	{}	2026-09-23	\N
6527	348	102	f	\N	\N	2026-09-19 14:52:08.382546+07	28	auto	\N	\N	\N	{}	2026-09-23	\N
6528	348	77	f	\N	\N	2026-09-19 14:52:08.382546+07	27	auto	\N	\N	\N	{}	2026-09-24	\N
6529	348	96	f	\N	\N	2026-09-19 14:52:08.382546+07	28	auto	\N	\N	\N	{}	2026-09-24	\N
6530	348	88	f	\N	\N	2026-09-19 14:52:08.382546+07	27	auto	\N	\N	\N	{}	2026-09-25	\N
6531	349	101	f	\N	\N	2026-09-19 14:52:08.527659+07	29	auto	\N	\N	\N	{}	\N	\N
6532	349	105	f	\N	\N	2026-09-19 14:52:08.527659+07	30	auto	\N	\N	\N	{}	\N	\N
6533	349	47	f	\N	\N	2026-09-19 14:52:08.527659+07	28	auto	\N	\N	\N	{}	2026-09-25	\N
6534	349	49	f	\N	\N	2026-09-19 14:52:08.527659+07	27	auto	\N	\N	\N	{}	2026-09-26	\N
6535	349	83	f	\N	\N	2026-09-19 14:52:08.527659+07	28	auto	\N	\N	\N	{}	2026-09-26	\N
6536	349	90	f	\N	\N	2026-09-19 14:52:08.527659+07	27	auto	\N	\N	\N	{}	2026-09-27	\N
6537	349	103	f	\N	\N	2026-09-19 14:52:08.527659+07	28	auto	\N	\N	\N	{}	2026-09-27	\N
6538	349	42	f	\N	\N	2026-09-19 14:52:08.527659+07	27	auto	\N	\N	\N	{}	2026-09-28	\N
6539	349	71	f	\N	\N	2026-09-19 14:52:08.527659+07	28	auto	\N	\N	\N	{}	2026-09-28	\N
6540	349	78	f	\N	\N	2026-09-19 14:52:08.527659+07	27	auto	\N	\N	\N	{}	2026-09-29	\N
6541	350	76	f	\N	\N	2026-09-19 14:52:08.653848+07	29	auto	\N	\N	\N	{}	\N	\N
6542	350	109	f	\N	\N	2026-09-19 14:52:08.653848+07	30	auto	\N	\N	\N	{}	\N	\N
6543	350	93	f	\N	\N	2026-09-19 14:52:08.653848+07	28	auto	\N	\N	\N	{}	2026-09-29	\N
6544	350	97	f	\N	\N	2026-09-19 14:52:08.653848+07	27	auto	\N	\N	\N	{}	2026-09-30	\N
6545	350	29	f	\N	\N	2026-09-19 14:52:08.653848+07	28	auto	\N	\N	\N	{}	2026-09-30	\N
6546	350	89	f	\N	\N	2026-09-19 14:52:08.653848+07	27	auto	\N	\N	\N	{}	2026-10-01	\N
6547	350	36	f	\N	\N	2026-09-19 14:52:08.653848+07	28	auto	\N	\N	\N	{}	2026-10-01	\N
6548	350	87	f	\N	\N	2026-09-19 14:52:08.653848+07	27	auto	\N	\N	\N	{}	2026-10-02	\N
10742	1006	123	f	\N	\N	2026-09-19 14:56:59.292248+07	6	auto	\N	\N	\N	{}	\N	\N
10743	1006	124	f	\N	\N	2026-09-19 14:56:59.292248+07	7	auto	\N	\N	\N	{}	\N	\N
10744	1006	28	f	\N	\N	2026-09-19 14:56:59.292248+07	13	auto	\N	\N	\N	{}	\N	\N
10745	1006	78	f	\N	\N	2026-09-19 14:56:59.292248+07	12	auto	\N	\N	\N	{}	\N	\N
10746	1006	45	f	\N	\N	2026-09-19 14:56:59.292248+07	16	auto	\N	\N	\N	{}	\N	\N
10747	1006	43	f	\N	\N	2026-09-19 14:56:59.292248+07	17	auto	\N	\N	\N	{}	\N	\N
10748	1006	46	f	\N	\N	2026-09-19 14:56:59.292248+07	14	auto	\N	\N	\N	{}	\N	\N
10749	1006	48	f	\N	\N	2026-09-19 14:56:59.292248+07	15	auto	\N	\N	\N	{}	\N	\N
10750	1006	71	f	\N	\N	2026-09-19 14:56:59.292248+07	8	auto	\N	\N	\N	{}	\N	\N
10751	1006	47	f	\N	\N	2026-09-19 14:56:59.292248+07	9	auto	\N	\N	\N	{}	\N	\N
10752	1006	29	f	\N	\N	2026-09-19 14:56:59.292248+07	10	auto	\N	\N	\N	{}	\N	\N
10753	1006	5	f	\N	\N	2026-09-19 14:56:59.292248+07	11	auto	\N	\N	\N	{}	\N	\N
10754	1007	113	f	\N	\N	2026-09-19 14:56:59.301466+07	6	auto	\N	\N	\N	{}	\N	\N
10755	1007	114	f	\N	\N	2026-09-19 14:56:59.301466+07	7	auto	\N	\N	\N	{}	\N	\N
10756	1007	73	f	\N	\N	2026-09-19 14:56:59.301466+07	13	auto	\N	\N	\N	{}	\N	\N
10757	1007	82	f	\N	\N	2026-09-19 14:56:59.301466+07	12	auto	\N	\N	\N	{}	\N	\N
10758	1007	51	f	\N	\N	2026-09-19 14:56:59.301466+07	16	auto	\N	\N	\N	{}	\N	\N
10759	1007	53	f	\N	\N	2026-09-19 14:56:59.301466+07	17	auto	\N	\N	\N	{}	\N	\N
10760	1007	25	f	\N	\N	2026-09-19 14:56:59.301466+07	14	auto	\N	\N	\N	{}	\N	\N
10761	1007	54	f	\N	\N	2026-09-19 14:56:59.301466+07	15	auto	\N	\N	\N	{}	\N	\N
10762	1007	70	f	\N	\N	2026-09-19 14:56:59.301466+07	8	auto	\N	\N	\N	{}	\N	\N
10763	1007	90	f	\N	\N	2026-09-19 14:56:59.301466+07	9	auto	\N	\N	\N	{}	\N	\N
10764	1007	75	f	\N	\N	2026-09-19 14:56:59.301466+07	10	auto	\N	\N	\N	{}	\N	\N
10765	1007	55	f	\N	\N	2026-09-19 14:56:59.301466+07	11	auto	\N	\N	\N	{}	\N	\N
10766	1008	115	f	\N	\N	2026-09-19 14:56:59.302752+07	6	auto	\N	\N	\N	{}	\N	\N
10767	1008	117	f	\N	\N	2026-09-19 14:56:59.302752+07	7	auto	\N	\N	\N	{}	\N	\N
10768	1008	83	f	\N	\N	2026-09-19 14:56:59.302752+07	13	auto	\N	\N	\N	{}	\N	\N
10769	1008	17	f	\N	\N	2026-09-19 14:56:59.302752+07	12	auto	\N	\N	\N	{}	\N	\N
10770	1008	61	f	\N	\N	2026-09-19 14:56:59.302752+07	16	auto	\N	\N	\N	{}	\N	\N
10771	1008	57	f	\N	\N	2026-09-19 14:56:59.302752+07	17	auto	\N	\N	\N	{}	\N	\N
10772	1008	60	f	\N	\N	2026-09-19 14:56:59.302752+07	14	auto	\N	\N	\N	{}	\N	\N
10773	1008	52	f	\N	\N	2026-09-19 14:56:59.302752+07	15	auto	\N	\N	\N	{}	\N	\N
10774	1008	77	f	\N	\N	2026-09-19 14:56:59.302752+07	8	auto	\N	\N	\N	{}	\N	\N
10775	1008	63	f	\N	\N	2026-09-19 14:56:59.302752+07	9	auto	\N	\N	\N	{}	\N	\N
10776	1008	72	f	\N	\N	2026-09-19 14:56:59.302752+07	10	auto	\N	\N	\N	{}	\N	\N
10777	1009	118	f	\N	\N	2026-09-19 14:56:59.303935+07	6	auto	\N	\N	\N	{}	\N	\N
10778	1009	119	f	\N	\N	2026-09-19 14:56:59.303935+07	7	auto	\N	\N	\N	{}	\N	\N
10779	1009	85	f	\N	\N	2026-09-19 14:56:59.303935+07	13	auto	\N	\N	\N	{}	\N	\N
10780	1009	76	f	\N	\N	2026-09-19 14:56:59.303935+07	12	auto	\N	\N	\N	{}	\N	\N
10781	1009	65	f	\N	\N	2026-09-19 14:56:59.303935+07	16	auto	\N	\N	\N	{}	\N	\N
10782	1009	67	f	\N	\N	2026-09-19 14:56:59.303935+07	17	auto	\N	\N	\N	{}	\N	\N
10783	1009	58	f	\N	\N	2026-09-19 14:56:59.303935+07	14	auto	\N	\N	\N	{}	\N	\N
10784	1009	64	f	\N	\N	2026-09-19 14:56:59.303935+07	15	auto	\N	\N	\N	{}	\N	\N
10785	1009	84	f	\N	\N	2026-09-19 14:56:59.303935+07	8	auto	\N	\N	\N	{}	\N	\N
10786	1009	42	f	\N	\N	2026-09-19 14:56:59.303935+07	9	auto	\N	\N	\N	{}	\N	\N
10787	1009	81	f	\N	\N	2026-09-19 14:56:59.303935+07	10	auto	\N	\N	\N	{}	\N	\N
10788	1009	36	f	\N	\N	2026-09-19 14:56:59.303935+07	11	auto	\N	\N	\N	{}	\N	\N
10789	1010	121	f	\N	\N	2026-09-19 14:56:59.305132+07	6	auto	\N	\N	\N	{}	\N	\N
10790	1010	125	f	\N	\N	2026-09-19 14:56:59.305132+07	7	auto	\N	\N	\N	{}	\N	\N
10791	1010	87	f	\N	\N	2026-09-19 14:56:59.305132+07	13	auto	\N	\N	\N	{}	\N	\N
10792	1010	88	f	\N	\N	2026-09-19 14:56:59.305132+07	12	auto	\N	\N	\N	{}	\N	\N
10793	1010	49	f	\N	\N	2026-09-19 14:56:59.305132+07	16	auto	\N	\N	\N	{}	\N	\N
10794	1010	69	f	\N	\N	2026-09-19 14:56:59.305132+07	17	auto	\N	\N	\N	{}	\N	\N
10795	1010	37	f	\N	\N	2026-09-19 14:56:59.305132+07	14	auto	\N	\N	\N	{}	\N	\N
10796	1010	66	f	\N	\N	2026-09-19 14:56:59.305132+07	15	auto	\N	\N	\N	{}	\N	\N
10797	1010	4	f	\N	\N	2026-09-19 14:56:59.305132+07	8	auto	\N	\N	\N	{}	\N	\N
10798	1010	12	f	\N	\N	2026-09-19 14:56:59.305132+07	9	auto	\N	\N	\N	{}	\N	\N
10799	1011	126	f	\N	\N	2026-09-19 14:56:59.306267+07	6	auto	\N	\N	\N	{}	\N	\N
10800	1011	127	f	\N	\N	2026-09-19 14:56:59.306267+07	7	auto	\N	\N	\N	{}	\N	\N
10801	1011	89	f	\N	\N	2026-09-19 14:56:59.306267+07	13	auto	\N	\N	\N	{}	\N	\N
10802	1011	24	f	\N	\N	2026-09-19 14:56:59.306267+07	16	auto	\N	\N	\N	{}	\N	\N
10803	1011	41	f	\N	\N	2026-09-19 14:56:59.306267+07	17	auto	\N	\N	\N	{}	\N	\N
10804	1011	91	f	\N	\N	2026-09-19 14:56:59.306267+07	10	auto	\N	\N	\N	{}	\N	\N
10805	1011	16	f	\N	\N	2026-09-19 14:56:59.306267+07	11	auto	\N	\N	\N	{}	\N	\N
10806	1012	129	f	\N	\N	2026-09-19 14:56:59.30729+07	6	auto	\N	\N	\N	{}	\N	\N
10807	1012	130	f	\N	\N	2026-09-19 14:56:59.30729+07	7	auto	\N	\N	\N	{}	\N	\N
10808	1012	32	f	\N	\N	2026-09-19 14:56:59.30729+07	13	auto	\N	\N	\N	{}	\N	\N
10809	1013	131	f	\N	\N	2026-09-19 14:56:59.308211+07	6	auto	\N	\N	\N	{}	\N	\N
10810	1013	132	f	\N	\N	2026-09-19 14:56:59.308211+07	7	auto	\N	\N	\N	{}	\N	\N
10811	1014	133	f	\N	\N	2026-09-19 14:56:59.309124+07	6	auto	\N	\N	\N	{}	\N	\N
10812	1014	8	f	\N	\N	2026-09-19 14:56:59.309124+07	7	auto	\N	\N	\N	{}	\N	\N
10813	1015	135	f	\N	\N	2026-09-19 14:56:59.310045+07	6	auto	\N	\N	\N	{}	\N	\N
10814	1015	9	f	\N	\N	2026-09-19 14:56:59.310045+07	7	auto	\N	\N	\N	{}	\N	\N
10815	1016	136	f	\N	\N	2026-09-19 14:56:59.310999+07	6	auto	\N	\N	\N	{}	\N	\N
10816	1016	94	f	\N	\N	2026-09-19 14:56:59.310999+07	7	auto	\N	\N	\N	{}	\N	\N
10817	1017	137	f	\N	\N	2026-09-19 14:57:03.73217+07	6	auto	\N	\N	\N	{}	\N	\N
10818	1017	97	f	\N	\N	2026-09-19 14:57:03.73217+07	7	auto	\N	\N	\N	{}	\N	\N
10819	1017	28	f	\N	\N	2026-09-19 14:57:03.73217+07	13	auto	\N	\N	\N	{}	\N	\N
10820	1017	5	f	\N	\N	2026-09-19 14:57:03.73217+07	12	auto	\N	\N	\N	{}	\N	\N
10821	1017	45	f	\N	\N	2026-09-19 14:57:03.73217+07	16	auto	\N	\N	\N	{}	\N	\N
10822	1017	47	f	\N	\N	2026-09-19 14:57:03.73217+07	17	auto	\N	\N	\N	{}	\N	\N
10823	1017	46	f	\N	\N	2026-09-19 14:57:03.73217+07	14	auto	\N	\N	\N	{}	\N	\N
10824	1017	48	f	\N	\N	2026-09-19 14:57:03.73217+07	15	auto	\N	\N	\N	{}	\N	\N
10825	1017	29	f	\N	\N	2026-09-19 14:57:03.73217+07	8	auto	\N	\N	\N	{}	\N	\N
10826	1017	78	f	\N	\N	2026-09-19 14:57:03.73217+07	9	auto	\N	\N	\N	{}	\N	\N
10827	1017	71	f	\N	\N	2026-09-19 14:57:03.73217+07	10	auto	\N	\N	\N	{}	\N	\N
10828	1017	43	f	\N	\N	2026-09-19 14:57:03.73217+07	11	auto	\N	\N	\N	{}	\N	\N
10829	1018	138	f	\N	\N	2026-09-19 14:57:03.865095+07	6	auto	\N	\N	\N	{}	\N	\N
10830	1018	99	f	\N	\N	2026-09-19 14:57:03.865095+07	7	auto	\N	\N	\N	{}	\N	\N
10831	1018	75	f	\N	\N	2026-09-19 14:57:03.865095+07	13	auto	\N	\N	\N	{}	\N	\N
10832	1018	70	f	\N	\N	2026-09-19 14:57:03.865095+07	12	auto	\N	\N	\N	{}	\N	\N
10833	1018	51	f	\N	\N	2026-09-19 14:57:03.865095+07	16	auto	\N	\N	\N	{}	\N	\N
10834	1018	53	f	\N	\N	2026-09-19 14:57:03.865095+07	17	auto	\N	\N	\N	{}	\N	\N
10835	1018	25	f	\N	\N	2026-09-19 14:57:03.865095+07	14	auto	\N	\N	\N	{}	\N	\N
10836	1018	54	f	\N	\N	2026-09-19 14:57:03.865095+07	15	auto	\N	\N	\N	{}	\N	\N
10837	1018	73	f	\N	\N	2026-09-19 14:57:03.865095+07	8	auto	\N	\N	\N	{}	\N	\N
10838	1018	55	f	\N	\N	2026-09-19 14:57:03.865095+07	9	auto	\N	\N	\N	{}	\N	\N
10839	1018	82	f	\N	\N	2026-09-19 14:57:03.865095+07	10	auto	\N	\N	\N	{}	\N	\N
10840	1018	90	f	\N	\N	2026-09-19 14:57:03.865095+07	11	auto	\N	\N	\N	{}	\N	\N
10841	1019	139	f	\N	\N	2026-09-19 14:57:04.004503+07	6	auto	\N	\N	\N	{}	\N	\N
10842	1019	101	f	\N	\N	2026-09-19 14:57:04.004503+07	7	auto	\N	\N	\N	{}	\N	\N
10843	1019	77	f	\N	\N	2026-09-19 14:57:04.004503+07	13	auto	\N	\N	\N	{}	\N	\N
10844	1019	17	f	\N	\N	2026-09-19 14:57:04.004503+07	12	auto	\N	\N	\N	{}	\N	\N
10845	1019	57	f	\N	\N	2026-09-19 14:57:04.004503+07	16	auto	\N	\N	\N	{}	\N	\N
10846	1019	61	f	\N	\N	2026-09-19 14:57:04.004503+07	17	auto	\N	\N	\N	{}	\N	\N
10847	1019	60	f	\N	\N	2026-09-19 14:57:04.004503+07	14	auto	\N	\N	\N	{}	\N	\N
10848	1019	52	f	\N	\N	2026-09-19 14:57:04.004503+07	15	auto	\N	\N	\N	{}	\N	\N
10849	1019	72	f	\N	\N	2026-09-19 14:57:04.004503+07	8	auto	\N	\N	\N	{}	\N	\N
10850	1019	58	f	\N	\N	2026-09-19 14:57:04.004503+07	9	auto	\N	\N	\N	{}	\N	\N
10851	1019	83	f	\N	\N	2026-09-19 14:57:04.004503+07	10	auto	\N	\N	\N	{}	\N	\N
10852	1019	63	f	\N	\N	2026-09-19 14:57:04.004503+07	11	auto	\N	\N	\N	{}	\N	\N
10853	1020	142	f	\N	\N	2026-09-19 14:57:04.136352+07	6	auto	\N	\N	\N	{}	\N	\N
10854	1020	103	f	\N	\N	2026-09-19 14:57:04.136352+07	7	auto	\N	\N	\N	{}	\N	\N
10855	1020	85	f	\N	\N	2026-09-19 14:57:04.136352+07	13	auto	\N	\N	\N	{}	\N	\N
10856	1020	76	f	\N	\N	2026-09-19 14:57:04.136352+07	12	auto	\N	\N	\N	{}	\N	\N
10857	1020	36	f	\N	\N	2026-09-19 14:57:04.136352+07	16	auto	\N	\N	\N	{}	\N	\N
10858	1020	65	f	\N	\N	2026-09-19 14:57:04.136352+07	17	auto	\N	\N	\N	{}	\N	\N
10859	1020	42	f	\N	\N	2026-09-19 14:57:04.136352+07	14	auto	\N	\N	\N	{}	\N	\N
10860	1020	64	f	\N	\N	2026-09-19 14:57:04.136352+07	15	auto	\N	\N	\N	{}	\N	\N
10861	1020	81	f	\N	\N	2026-09-19 14:57:04.136352+07	8	auto	\N	\N	\N	{}	\N	\N
10862	1020	67	f	\N	\N	2026-09-19 14:57:04.136352+07	9	auto	\N	\N	\N	{}	\N	\N
10863	1020	84	f	\N	\N	2026-09-19 14:57:04.136352+07	10	auto	\N	\N	\N	{}	\N	\N
10864	1020	37	f	\N	\N	2026-09-19 14:57:04.136352+07	11	auto	\N	\N	\N	{}	\N	\N
10865	1021	143	f	\N	\N	2026-09-19 14:57:04.355197+07	6	auto	\N	\N	\N	{}	\N	\N
10866	1021	105	f	\N	\N	2026-09-19 14:57:04.355197+07	7	auto	\N	\N	\N	{}	\N	\N
10867	1021	4	f	\N	\N	2026-09-19 14:57:04.355197+07	13	auto	\N	\N	\N	{}	\N	\N
10868	1021	88	f	\N	\N	2026-09-19 14:57:04.355197+07	12	auto	\N	\N	\N	{}	\N	\N
10869	1021	12	f	\N	\N	2026-09-19 14:57:04.355197+07	16	auto	\N	\N	\N	{}	\N	\N
10870	1021	49	f	\N	\N	2026-09-19 14:57:04.355197+07	17	auto	\N	\N	\N	{}	\N	\N
10871	1021	66	f	\N	\N	2026-09-19 14:57:04.355197+07	14	auto	\N	\N	\N	{}	\N	\N
10872	1021	46	f	\N	\N	2026-09-19 14:57:04.355197+07	15	auto	\N	\N	\N	{}	\N	\N
10873	1021	5	f	\N	\N	2026-09-19 14:57:04.355197+07	8	auto	\N	\N	\N	{}	\N	\N
10874	1021	29	f	\N	\N	2026-09-19 14:57:04.355197+07	9	auto	\N	\N	\N	{}	\N	\N
10875	1021	87	f	\N	\N	2026-09-19 14:57:04.355197+07	10	auto	\N	\N	\N	{}	\N	\N
10876	1021	69	f	\N	\N	2026-09-19 14:57:04.355197+07	11	auto	\N	\N	\N	{}	\N	\N
10877	1022	144	f	\N	\N	2026-09-19 14:57:04.359803+07	6	auto	\N	\N	\N	{}	\N	\N
10878	1022	106	f	\N	\N	2026-09-19 14:57:04.359803+07	7	auto	\N	\N	\N	{}	\N	\N
10879	1022	89	f	\N	\N	2026-09-19 14:57:04.359803+07	13	auto	\N	\N	\N	{}	\N	\N
10880	1022	78	f	\N	\N	2026-09-19 14:57:04.359803+07	12	auto	\N	\N	\N	{}	\N	\N
10881	1022	24	f	\N	\N	2026-09-19 14:57:04.359803+07	16	auto	\N	\N	\N	{}	\N	\N
10882	1022	41	f	\N	\N	2026-09-19 14:57:04.359803+07	17	auto	\N	\N	\N	{}	\N	\N
10883	1022	48	f	\N	\N	2026-09-19 14:57:04.359803+07	14	auto	\N	\N	\N	{}	\N	\N
10884	1022	25	f	\N	\N	2026-09-19 14:57:04.359803+07	15	auto	\N	\N	\N	{}	\N	\N
10885	1022	16	f	\N	\N	2026-09-19 14:57:04.359803+07	8	auto	\N	\N	\N	{}	\N	\N
10886	1022	91	f	\N	\N	2026-09-19 14:57:04.359803+07	9	auto	\N	\N	\N	{}	\N	\N
10887	1022	70	f	\N	\N	2026-09-19 14:57:04.359803+07	10	auto	\N	\N	\N	{}	\N	\N
10888	1022	54	f	\N	\N	2026-09-19 14:57:04.359803+07	11	auto	\N	\N	\N	{}	\N	\N
10889	1023	145	f	\N	\N	2026-09-19 14:57:04.361401+07	6	auto	\N	\N	\N	{}	\N	\N
10890	1023	93	f	\N	\N	2026-09-19 14:57:04.361401+07	7	auto	\N	\N	\N	{}	\N	\N
10891	1023	32	f	\N	\N	2026-09-19 14:57:04.361401+07	13	auto	\N	\N	\N	{}	\N	\N
10892	1023	82	f	\N	\N	2026-09-19 14:57:04.361401+07	12	auto	\N	\N	\N	{}	\N	\N
10893	1023	43	f	\N	\N	2026-09-19 14:57:04.361401+07	16	auto	\N	\N	\N	{}	\N	\N
10894	1023	45	f	\N	\N	2026-09-19 14:57:04.361401+07	17	auto	\N	\N	\N	{}	\N	\N
10895	1023	58	f	\N	\N	2026-09-19 14:57:04.361401+07	14	auto	\N	\N	\N	{}	\N	\N
10896	1023	60	f	\N	\N	2026-09-19 14:57:04.361401+07	15	auto	\N	\N	\N	{}	\N	\N
10897	1023	90	f	\N	\N	2026-09-19 14:57:04.361401+07	8	auto	\N	\N	\N	{}	\N	\N
10898	1023	17	f	\N	\N	2026-09-19 14:57:04.361401+07	9	auto	\N	\N	\N	{}	\N	\N
10899	1023	28	f	\N	\N	2026-09-19 14:57:04.361401+07	10	auto	\N	\N	\N	{}	\N	\N
10900	1023	47	f	\N	\N	2026-09-19 14:57:04.361401+07	11	auto	\N	\N	\N	{}	\N	\N
10901	1024	147	f	\N	\N	2026-09-19 14:57:04.822903+07	6	auto	\N	\N	\N	{}	\N	\N
10902	1024	96	f	\N	\N	2026-09-19 14:57:04.822903+07	7	auto	\N	\N	\N	{}	\N	\N
10903	1024	71	f	\N	\N	2026-09-19 14:57:04.822903+07	13	auto	\N	\N	\N	{}	\N	\N
10904	1024	72	f	\N	\N	2026-09-19 14:57:04.822903+07	12	auto	\N	\N	\N	{}	\N	\N
10905	1024	51	f	\N	\N	2026-09-19 14:57:04.822903+07	16	auto	\N	\N	\N	{}	\N	\N
10906	1024	53	f	\N	\N	2026-09-19 14:57:04.822903+07	17	auto	\N	\N	\N	{}	\N	\N
10907	1024	52	f	\N	\N	2026-09-19 14:57:04.822903+07	14	auto	\N	\N	\N	{}	\N	\N
10908	1024	37	f	\N	\N	2026-09-19 14:57:04.822903+07	15	auto	\N	\N	\N	{}	\N	\N
10909	1024	75	f	\N	\N	2026-09-19 14:57:04.822903+07	8	auto	\N	\N	\N	{}	\N	\N
10910	1024	55	f	\N	\N	2026-09-19 14:57:04.822903+07	9	auto	\N	\N	\N	{}	\N	\N
10911	1024	76	f	\N	\N	2026-09-19 14:57:04.822903+07	10	auto	\N	\N	\N	{}	\N	\N
10912	1024	42	f	\N	\N	2026-09-19 14:57:04.822903+07	11	auto	\N	\N	\N	{}	\N	\N
10949	1028	22	f	\N	\N	2026-09-19 14:57:05.454097+07	6	auto	\N	\N	\N	{}	\N	\N
10950	1028	108	f	\N	\N	2026-09-19 14:57:05.454097+07	7	auto	\N	\N	\N	{}	\N	\N
10951	1028	87	f	\N	\N	2026-09-19 14:57:05.454097+07	13	auto	\N	\N	\N	{}	\N	\N
10952	1028	82	f	\N	\N	2026-09-19 14:57:05.454097+07	12	auto	\N	\N	\N	{}	\N	\N
10953	1028	24	f	\N	\N	2026-09-19 14:57:05.454097+07	16	auto	\N	\N	\N	{}	\N	\N
10954	1028	41	f	\N	\N	2026-09-19 14:57:05.454097+07	17	auto	\N	\N	\N	{}	\N	\N
10955	1028	52	f	\N	\N	2026-09-19 14:57:05.454097+07	14	auto	\N	\N	\N	{}	\N	\N
10956	1028	37	f	\N	\N	2026-09-19 14:57:05.454097+07	15	auto	\N	\N	\N	{}	\N	\N
10957	1028	16	f	\N	\N	2026-09-19 14:57:05.454097+07	8	auto	\N	\N	\N	{}	\N	\N
10958	1028	89	f	\N	\N	2026-09-19 14:57:05.454097+07	9	auto	\N	\N	\N	{}	\N	\N
10959	1028	90	f	\N	\N	2026-09-19 14:57:05.454097+07	10	auto	\N	\N	\N	{}	\N	\N
10960	1028	42	f	\N	\N	2026-09-19 14:57:05.454097+07	11	auto	\N	\N	\N	{}	\N	\N
10961	1029	34	f	\N	\N	2026-09-19 14:57:05.458976+07	6	auto	\N	\N	\N	{}	\N	\N
10962	1029	109	f	\N	\N	2026-09-19 14:57:05.458976+07	7	auto	\N	\N	\N	{}	\N	\N
10963	1029	91	f	\N	\N	2026-09-19 14:57:05.458976+07	13	auto	\N	\N	\N	{}	\N	\N
10964	1029	72	f	\N	\N	2026-09-19 14:57:05.458976+07	12	auto	\N	\N	\N	{}	\N	\N
10965	1029	43	f	\N	\N	2026-09-19 14:57:05.458976+07	16	auto	\N	\N	\N	{}	\N	\N
10966	1029	45	f	\N	\N	2026-09-19 14:57:05.458976+07	17	auto	\N	\N	\N	{}	\N	\N
10967	1029	46	f	\N	\N	2026-09-19 14:57:05.458976+07	14	auto	\N	\N	\N	{}	\N	\N
10968	1029	64	f	\N	\N	2026-09-19 14:57:05.458976+07	15	auto	\N	\N	\N	{}	\N	\N
10969	1029	76	f	\N	\N	2026-09-19 14:57:05.458976+07	8	auto	\N	\N	\N	{}	\N	\N
10970	1029	5	f	\N	\N	2026-09-19 14:57:05.458976+07	9	auto	\N	\N	\N	{}	\N	\N
10971	1029	28	f	\N	\N	2026-09-19 14:57:05.458976+07	10	auto	\N	\N	\N	{}	\N	\N
10972	1029	47	f	\N	\N	2026-09-19 14:57:05.458976+07	11	auto	\N	\N	\N	{}	\N	\N
10973	1030	35	f	\N	\N	2026-09-19 14:57:05.460796+07	6	auto	\N	\N	\N	{}	\N	\N
10974	1030	111	f	\N	\N	2026-09-19 14:57:05.460796+07	7	auto	\N	\N	\N	{}	\N	\N
10975	1030	71	f	\N	\N	2026-09-19 14:57:05.460796+07	13	auto	\N	\N	\N	{}	\N	\N
10976	1030	29	f	\N	\N	2026-09-19 14:57:05.460796+07	12	auto	\N	\N	\N	{}	\N	\N
10977	1030	51	f	\N	\N	2026-09-19 14:57:05.460796+07	16	auto	\N	\N	\N	{}	\N	\N
10978	1030	53	f	\N	\N	2026-09-19 14:57:05.460796+07	17	auto	\N	\N	\N	{}	\N	\N
10979	1030	25	f	\N	\N	2026-09-19 14:57:05.460796+07	14	auto	\N	\N	\N	{}	\N	\N
10980	1030	48	f	\N	\N	2026-09-19 14:57:05.460796+07	15	auto	\N	\N	\N	{}	\N	\N
10981	1030	75	f	\N	\N	2026-09-19 14:57:05.460796+07	8	auto	\N	\N	\N	{}	\N	\N
10982	1030	55	f	\N	\N	2026-09-19 14:57:05.460796+07	9	auto	\N	\N	\N	{}	\N	\N
10983	1030	84	f	\N	\N	2026-09-19 14:57:05.460796+07	10	auto	\N	\N	\N	{}	\N	\N
10984	1030	70	f	\N	\N	2026-09-19 14:57:05.460796+07	11	auto	\N	\N	\N	{}	\N	\N
11129	1050	149	f	\N	\N	2026-09-19 14:57:08.880431+07	1	auto	\N	\N	\N	{}	\N	\N
11130	1050	124	f	\N	\N	2026-09-19 14:57:08.880431+07	2	auto	\N	\N	\N	{}	\N	\N
11131	1050	113	f	\N	\N	2026-09-19 14:57:08.880431+07	3	auto	\N	\N	\N	{}	\N	\N
11132	1050	7	f	\N	\N	2026-09-19 14:57:08.880431+07	4	auto	\N	\N	\N	{}	\N	\N
11133	1050	14	f	\N	\N	2026-09-19 14:57:08.880431+07	5	auto	\N	\N	\N	{}	\N	\N
11144	1053	121	f	\N	\N	2026-09-19 14:57:09.170441+07	1	auto	\N	\N	\N	{}	\N	\N
11145	1053	125	f	\N	\N	2026-09-19 14:57:09.170441+07	2	auto	\N	\N	\N	{}	\N	\N
11146	1053	126	f	\N	\N	2026-09-19 14:57:09.170441+07	3	auto	\N	\N	\N	{}	\N	\N
11147	1053	27	f	\N	\N	2026-09-19 14:57:09.170441+07	4	auto	\N	\N	\N	{}	\N	\N
11148	1053	38	f	\N	\N	2026-09-19 14:57:09.170441+07	5	auto	\N	\N	\N	{}	\N	\N
11149	1054	127	f	\N	\N	2026-09-19 14:57:09.171963+07	1	auto	\N	\N	\N	{}	\N	\N
11150	1054	129	f	\N	\N	2026-09-19 14:57:09.171963+07	2	auto	\N	\N	\N	{}	\N	\N
11151	1054	130	f	\N	\N	2026-09-19 14:57:09.171963+07	3	auto	\N	\N	\N	{}	\N	\N
11152	1054	39	f	\N	\N	2026-09-19 14:57:09.171963+07	4	auto	\N	\N	\N	{}	\N	\N
11153	1054	96	f	\N	\N	2026-09-19 14:57:09.171963+07	5	auto	\N	\N	\N	{}	\N	\N
11154	1055	131	f	\N	\N	2026-09-19 14:57:09.173109+07	1	auto	\N	\N	\N	{}	\N	\N
11155	1055	132	f	\N	\N	2026-09-19 14:57:09.173109+07	2	auto	\N	\N	\N	{}	\N	\N
11156	1055	22	f	\N	\N	2026-09-19 14:57:09.173109+07	3	auto	\N	\N	\N	{}	\N	\N
11157	1055	8	f	\N	\N	2026-09-19 14:57:09.173109+07	4	auto	\N	\N	\N	{}	\N	\N
11158	1055	102	f	\N	\N	2026-09-19 14:57:09.173109+07	5	auto	\N	\N	\N	{}	\N	\N
11169	1058	111	f	\N	\N	2026-09-19 14:57:09.569694+07	1	auto	\N	\N	\N	{}	\N	\N
11170	1058	136	f	\N	\N	2026-09-19 14:57:09.569694+07	2	auto	\N	\N	\N	{}	\N	\N
11171	1058	112	f	\N	\N	2026-09-19 14:57:09.569694+07	3	auto	\N	\N	\N	{}	\N	\N
11172	1058	6	f	\N	\N	2026-09-19 14:57:09.569694+07	4	auto	\N	\N	\N	{}	\N	\N
11173	1058	97	f	\N	\N	2026-09-19 14:57:09.569694+07	5	auto	\N	\N	\N	{}	\N	\N
11209	1066	144	f	\N	\N	2026-09-19 14:57:10.27523+07	1	auto	\N	\N	\N	{}	\N	\N
11210	1066	130	f	\N	\N	2026-09-19 14:57:10.27523+07	2	auto	\N	\N	\N	{}	\N	\N
11211	1066	131	f	\N	\N	2026-09-19 14:57:10.27523+07	3	auto	\N	\N	\N	{}	\N	\N
11212	1066	2	f	\N	\N	2026-09-19 14:57:10.27523+07	4	auto	\N	\N	\N	{}	\N	\N
11213	1066	94	f	\N	\N	2026-09-19 14:57:10.27523+07	5	auto	\N	\N	\N	{}	\N	\N
11214	1067	145	f	\N	\N	2026-09-19 14:57:10.408634+07	1	auto	\N	\N	\N	{}	\N	\N
11215	1067	132	f	\N	\N	2026-09-19 14:57:10.408634+07	2	auto	\N	\N	\N	{}	\N	\N
11216	1067	133	f	\N	\N	2026-09-19 14:57:10.408634+07	3	auto	\N	\N	\N	{}	\N	\N
11217	1067	102	f	\N	\N	2026-09-19 14:57:10.408634+07	4	auto	\N	\N	\N	{}	\N	\N
11218	1067	6	f	\N	\N	2026-09-19 14:57:10.408634+07	5	auto	\N	\N	\N	{}	\N	\N
11219	1068	147	f	\N	\N	2026-09-19 14:57:10.411571+07	1	auto	\N	\N	\N	{}	\N	\N
11220	1068	9	f	\N	\N	2026-09-19 14:57:10.411571+07	2	auto	\N	\N	\N	{}	\N	\N
11221	1068	135	f	\N	\N	2026-09-19 14:57:10.411571+07	3	auto	\N	\N	\N	{}	\N	\N
11222	1068	95	f	\N	\N	2026-09-19 14:57:10.411571+07	4	auto	\N	\N	\N	{}	\N	\N
11223	1068	97	f	\N	\N	2026-09-19 14:57:10.411571+07	5	auto	\N	\N	\N	{}	\N	\N
11224	1069	148	f	\N	\N	2026-09-19 14:57:10.415094+07	1	auto	\N	\N	\N	{}	\N	\N
11225	1069	136	f	\N	\N	2026-09-19 14:57:10.415094+07	2	auto	\N	\N	\N	{}	\N	\N
11226	1069	99	f	\N	\N	2026-09-19 14:57:10.415094+07	3	auto	\N	\N	\N	{}	\N	\N
11227	1069	7	f	\N	\N	2026-09-19 14:57:10.415094+07	4	auto	\N	\N	\N	{}	\N	\N
11228	1069	14	f	\N	\N	2026-09-19 14:57:10.415094+07	5	auto	\N	\N	\N	{}	\N	\N
10913	1025	148	f	\N	\N	2026-09-19 14:57:04.958238+07	6	auto	\N	\N	\N	{}	\N	\N
10914	1025	102	f	\N	\N	2026-09-19 14:57:04.958238+07	7	auto	\N	\N	\N	{}	\N	\N
10915	1025	73	f	\N	\N	2026-09-19 14:57:04.958238+07	13	auto	\N	\N	\N	{}	\N	\N
10916	1025	5	f	\N	\N	2026-09-19 14:57:04.958238+07	12	auto	\N	\N	\N	{}	\N	\N
10917	1025	57	f	\N	\N	2026-09-19 14:57:04.958238+07	16	auto	\N	\N	\N	{}	\N	\N
10918	1025	61	f	\N	\N	2026-09-19 14:57:04.958238+07	17	auto	\N	\N	\N	{}	\N	\N
10919	1025	64	f	\N	\N	2026-09-19 14:57:04.958238+07	14	auto	\N	\N	\N	{}	\N	\N
10920	1025	46	f	\N	\N	2026-09-19 14:57:04.958238+07	15	auto	\N	\N	\N	{}	\N	\N
10921	1025	84	f	\N	\N	2026-09-19 14:57:04.958238+07	8	auto	\N	\N	\N	{}	\N	\N
10922	1025	29	f	\N	\N	2026-09-19 14:57:04.958238+07	9	auto	\N	\N	\N	{}	\N	\N
10923	1025	77	f	\N	\N	2026-09-19 14:57:04.958238+07	10	auto	\N	\N	\N	{}	\N	\N
10924	1025	63	f	\N	\N	2026-09-19 14:57:04.958238+07	11	auto	\N	\N	\N	{}	\N	\N
10937	1027	150	f	\N	\N	2026-09-19 14:57:05.231835+07	6	auto	\N	\N	\N	{}	\N	\N
10938	1027	107	f	\N	\N	2026-09-19 14:57:05.231835+07	7	auto	\N	\N	\N	{}	\N	\N
10939	1027	85	f	\N	\N	2026-09-19 14:57:05.231835+07	13	auto	\N	\N	\N	{}	\N	\N
10940	1027	78	f	\N	\N	2026-09-19 14:57:05.231835+07	12	auto	\N	\N	\N	{}	\N	\N
10941	1027	12	f	\N	\N	2026-09-19 14:57:05.231835+07	16	auto	\N	\N	\N	{}	\N	\N
10942	1027	49	f	\N	\N	2026-09-19 14:57:05.231835+07	17	auto	\N	\N	\N	{}	\N	\N
10943	1027	54	f	\N	\N	2026-09-19 14:57:05.231835+07	14	auto	\N	\N	\N	{}	\N	\N
10944	1027	58	f	\N	\N	2026-09-19 14:57:05.231835+07	15	auto	\N	\N	\N	{}	\N	\N
10945	1027	17	f	\N	\N	2026-09-19 14:57:05.231835+07	8	auto	\N	\N	\N	{}	\N	\N
10946	1027	60	f	\N	\N	2026-09-19 14:57:05.231835+07	9	auto	\N	\N	\N	{}	\N	\N
10947	1027	4	f	\N	\N	2026-09-19 14:57:05.231835+07	10	auto	\N	\N	\N	{}	\N	\N
10948	1027	69	f	\N	\N	2026-09-19 14:57:05.231835+07	11	auto	\N	\N	\N	{}	\N	\N
10997	1032	124	f	\N	\N	2026-09-19 14:57:06.063521+07	6	auto	\N	\N	\N	{}	\N	\N
10998	1032	113	f	\N	\N	2026-09-19 14:57:06.063521+07	7	auto	\N	\N	\N	{}	\N	\N
10999	1032	83	f	\N	\N	2026-09-19 14:57:06.063521+07	13	auto	\N	\N	\N	{}	\N	\N
11000	1032	78	f	\N	\N	2026-09-19 14:57:06.063521+07	12	auto	\N	\N	\N	{}	\N	\N
11001	1032	36	f	\N	\N	2026-09-19 14:57:06.063521+07	16	auto	\N	\N	\N	{}	\N	\N
11002	1032	65	f	\N	\N	2026-09-19 14:57:06.063521+07	17	auto	\N	\N	\N	{}	\N	\N
11003	1032	54	f	\N	\N	2026-09-19 14:57:06.063521+07	14	auto	\N	\N	\N	{}	\N	\N
11004	1032	37	f	\N	\N	2026-09-19 14:57:06.063521+07	15	auto	\N	\N	\N	{}	\N	\N
11005	1032	81	f	\N	\N	2026-09-19 14:57:06.063521+07	8	auto	\N	\N	\N	{}	\N	\N
11006	1032	67	f	\N	\N	2026-09-19 14:57:06.063521+07	9	auto	\N	\N	\N	{}	\N	\N
11007	1032	82	f	\N	\N	2026-09-19 14:57:06.063521+07	10	auto	\N	\N	\N	{}	\N	\N
11008	1032	42	f	\N	\N	2026-09-19 14:57:06.063521+07	11	auto	\N	\N	\N	{}	\N	\N
11021	1034	117	f	\N	\N	2026-09-19 14:57:06.338813+07	6	auto	\N	\N	\N	{}	\N	\N
11022	1034	118	f	\N	\N	2026-09-19 14:57:06.338813+07	7	auto	\N	\N	\N	{}	\N	\N
11023	1034	16	f	\N	\N	2026-09-19 14:57:06.338813+07	13	auto	\N	\N	\N	{}	\N	\N
11024	1034	5	f	\N	\N	2026-09-19 14:57:06.338813+07	12	auto	\N	\N	\N	{}	\N	\N
11025	1034	69	f	\N	\N	2026-09-19 14:57:06.338813+07	16	auto	\N	\N	\N	{}	\N	\N
11026	1034	24	f	\N	\N	2026-09-19 14:57:06.338813+07	17	auto	\N	\N	\N	{}	\N	\N
11027	1034	46	f	\N	\N	2026-09-19 14:57:06.338813+07	14	auto	\N	\N	\N	{}	\N	\N
11028	1034	25	f	\N	\N	2026-09-19 14:57:06.338813+07	15	auto	\N	\N	\N	{}	\N	\N
11029	1034	87	f	\N	\N	2026-09-19 14:57:06.338813+07	8	auto	\N	\N	\N	{}	\N	\N
11030	1034	41	f	\N	\N	2026-09-19 14:57:06.338813+07	9	auto	\N	\N	\N	{}	\N	\N
11031	1034	84	f	\N	\N	2026-09-19 14:57:06.338813+07	10	auto	\N	\N	\N	{}	\N	\N
11032	1034	29	f	\N	\N	2026-09-19 14:57:06.338813+07	11	auto	\N	\N	\N	{}	\N	\N
10925	1026	149	f	\N	\N	2026-09-19 14:57:05.093475+07	6	auto	\N	\N	\N	{}	\N	\N
10926	1026	95	f	\N	\N	2026-09-19 14:57:05.093475+07	7	auto	\N	\N	\N	{}	\N	\N
10927	1026	83	f	\N	\N	2026-09-19 14:57:05.093475+07	13	auto	\N	\N	\N	{}	\N	\N
10928	1026	88	f	\N	\N	2026-09-19 14:57:05.093475+07	12	auto	\N	\N	\N	{}	\N	\N
10929	1026	36	f	\N	\N	2026-09-19 14:57:05.093475+07	16	auto	\N	\N	\N	{}	\N	\N
10930	1026	65	f	\N	\N	2026-09-19 14:57:05.093475+07	17	auto	\N	\N	\N	{}	\N	\N
10931	1026	66	f	\N	\N	2026-09-19 14:57:05.093475+07	14	auto	\N	\N	\N	{}	\N	\N
10932	1026	25	f	\N	\N	2026-09-19 14:57:05.093475+07	15	auto	\N	\N	\N	{}	\N	\N
10933	1026	81	f	\N	\N	2026-09-19 14:57:05.093475+07	8	auto	\N	\N	\N	{}	\N	\N
10934	1026	67	f	\N	\N	2026-09-19 14:57:05.093475+07	9	auto	\N	\N	\N	{}	\N	\N
10935	1026	70	f	\N	\N	2026-09-19 14:57:05.093475+07	10	auto	\N	\N	\N	{}	\N	\N
10936	1026	48	f	\N	\N	2026-09-19 14:57:05.093475+07	11	auto	\N	\N	\N	{}	\N	\N
10985	1031	112	f	\N	\N	2026-09-19 14:57:05.929032+07	6	auto	\N	\N	\N	{}	\N	\N
10986	1031	123	f	\N	\N	2026-09-19 14:57:05.929032+07	7	auto	\N	\N	\N	{}	\N	\N
10987	1031	73	f	\N	\N	2026-09-19 14:57:05.929032+07	13	auto	\N	\N	\N	{}	\N	\N
10988	1031	88	f	\N	\N	2026-09-19 14:57:05.929032+07	12	auto	\N	\N	\N	{}	\N	\N
10989	1031	57	f	\N	\N	2026-09-19 14:57:05.929032+07	16	auto	\N	\N	\N	{}	\N	\N
10990	1031	61	f	\N	\N	2026-09-19 14:57:05.929032+07	17	auto	\N	\N	\N	{}	\N	\N
10991	1031	66	f	\N	\N	2026-09-19 14:57:05.929032+07	14	auto	\N	\N	\N	{}	\N	\N
10992	1031	58	f	\N	\N	2026-09-19 14:57:05.929032+07	15	auto	\N	\N	\N	{}	\N	\N
10993	1031	17	f	\N	\N	2026-09-19 14:57:05.929032+07	8	auto	\N	\N	\N	{}	\N	\N
10994	1031	60	f	\N	\N	2026-09-19 14:57:05.929032+07	9	auto	\N	\N	\N	{}	\N	\N
10995	1031	77	f	\N	\N	2026-09-19 14:57:05.929032+07	10	auto	\N	\N	\N	{}	\N	\N
10996	1031	63	f	\N	\N	2026-09-19 14:57:05.929032+07	11	auto	\N	\N	\N	{}	\N	\N
11069	1038	115	f	\N	\N	2026-09-19 14:57:07.164673+07	1	auto	\N	\N	\N	{}	\N	\N
11070	1038	117	f	\N	\N	2026-09-19 14:57:07.164673+07	2	auto	\N	\N	\N	{}	\N	\N
11071	1038	118	f	\N	\N	2026-09-19 14:57:07.164673+07	3	auto	\N	\N	\N	{}	\N	\N
11072	1038	2	f	\N	\N	2026-09-19 14:57:07.164673+07	4	auto	\N	\N	\N	{}	\N	\N
11073	1038	6	f	\N	\N	2026-09-19 14:57:07.164673+07	5	auto	\N	\N	\N	{}	\N	\N
11074	1039	119	f	\N	\N	2026-09-19 14:57:07.165817+07	1	auto	\N	\N	\N	{}	\N	\N
11075	1039	121	f	\N	\N	2026-09-19 14:57:07.165817+07	2	auto	\N	\N	\N	{}	\N	\N
11076	1039	125	f	\N	\N	2026-09-19 14:57:07.165817+07	3	auto	\N	\N	\N	{}	\N	\N
11077	1039	7	f	\N	\N	2026-09-19 14:57:07.165817+07	4	auto	\N	\N	\N	{}	\N	\N
11078	1039	14	f	\N	\N	2026-09-19 14:57:07.165817+07	5	auto	\N	\N	\N	{}	\N	\N
11079	1040	126	f	\N	\N	2026-09-19 14:57:07.166885+07	1	auto	\N	\N	\N	{}	\N	\N
11080	1040	127	f	\N	\N	2026-09-19 14:57:07.166885+07	2	auto	\N	\N	\N	{}	\N	\N
11081	1040	129	f	\N	\N	2026-09-19 14:57:07.166885+07	3	auto	\N	\N	\N	{}	\N	\N
11082	1040	15	f	\N	\N	2026-09-19 14:57:07.166885+07	4	auto	\N	\N	\N	{}	\N	\N
11083	1040	18	f	\N	\N	2026-09-19 14:57:07.166885+07	5	auto	\N	\N	\N	{}	\N	\N
11084	1041	130	f	\N	\N	2026-09-19 14:57:07.16817+07	1	auto	\N	\N	\N	{}	\N	\N
11085	1041	131	f	\N	\N	2026-09-19 14:57:07.16817+07	2	auto	\N	\N	\N	{}	\N	\N
11086	1041	132	f	\N	\N	2026-09-19 14:57:07.16817+07	3	auto	\N	\N	\N	{}	\N	\N
11087	1041	19	f	\N	\N	2026-09-19 14:57:07.16817+07	4	auto	\N	\N	\N	{}	\N	\N
11088	1041	26	f	\N	\N	2026-09-19 14:57:07.16817+07	5	auto	\N	\N	\N	{}	\N	\N
11089	1042	133	f	\N	\N	2026-09-19 14:57:07.170727+07	1	auto	\N	\N	\N	{}	\N	\N
11090	1042	135	f	\N	\N	2026-09-19 14:57:07.170727+07	2	auto	\N	\N	\N	{}	\N	\N
11091	1042	8	f	\N	\N	2026-09-19 14:57:07.170727+07	3	auto	\N	\N	\N	{}	\N	\N
11092	1042	27	f	\N	\N	2026-09-19 14:57:07.170727+07	4	auto	\N	\N	\N	{}	\N	\N
11093	1042	38	f	\N	\N	2026-09-19 14:57:07.170727+07	5	auto	\N	\N	\N	{}	\N	\N
11094	1043	9	f	\N	\N	2026-09-19 14:57:07.171987+07	1	auto	\N	\N	\N	{}	\N	\N
11095	1043	136	f	\N	\N	2026-09-19 14:57:07.171987+07	2	auto	\N	\N	\N	{}	\N	\N
11096	1043	94	f	\N	\N	2026-09-19 14:57:07.171987+07	3	auto	\N	\N	\N	{}	\N	\N
11097	1043	39	f	\N	\N	2026-09-19 14:57:07.171987+07	4	auto	\N	\N	\N	{}	\N	\N
11098	1043	97	f	\N	\N	2026-09-19 14:57:07.171987+07	5	auto	\N	\N	\N	{}	\N	\N
11099	1044	137	f	\N	\N	2026-09-19 14:57:07.17544+07	1	auto	\N	\N	\N	{}	\N	\N
11100	1044	138	f	\N	\N	2026-09-19 14:57:07.17544+07	2	auto	\N	\N	\N	{}	\N	\N
11101	1044	99	f	\N	\N	2026-09-19 14:57:07.17544+07	3	auto	\N	\N	\N	{}	\N	\N
11102	1044	101	f	\N	\N	2026-09-19 14:57:07.17544+07	4	auto	\N	\N	\N	{}	\N	\N
11103	1044	103	f	\N	\N	2026-09-19 14:57:07.17544+07	5	auto	\N	\N	\N	{}	\N	\N
11104	1045	139	f	\N	\N	2026-09-19 14:57:07.177359+07	1	auto	\N	\N	\N	{}	\N	\N
11105	1045	142	f	\N	\N	2026-09-19 14:57:07.177359+07	2	auto	\N	\N	\N	{}	\N	\N
11106	1045	143	f	\N	\N	2026-09-19 14:57:07.177359+07	3	auto	\N	\N	\N	{}	\N	\N
11107	1045	105	f	\N	\N	2026-09-19 14:57:07.177359+07	4	auto	\N	\N	\N	{}	\N	\N
11108	1045	106	f	\N	\N	2026-09-19 14:57:07.177359+07	5	auto	\N	\N	\N	{}	\N	\N
11109	1046	144	f	\N	\N	2026-09-19 14:57:07.178241+07	1	auto	\N	\N	\N	{}	\N	\N
11110	1046	22	f	\N	\N	2026-09-19 14:57:07.178241+07	2	auto	\N	\N	\N	{}	\N	\N
11111	1046	93	f	\N	\N	2026-09-19 14:57:07.178241+07	3	auto	\N	\N	\N	{}	\N	\N
11112	1046	96	f	\N	\N	2026-09-19 14:57:07.178241+07	4	auto	\N	\N	\N	{}	\N	\N
11113	1046	102	f	\N	\N	2026-09-19 14:57:07.178241+07	5	auto	\N	\N	\N	{}	\N	\N
11114	1047	145	f	\N	\N	2026-09-19 14:57:07.179334+07	1	auto	\N	\N	\N	{}	\N	\N
11115	1047	34	f	\N	\N	2026-09-19 14:57:07.179334+07	2	auto	\N	\N	\N	{}	\N	\N
11116	1047	95	f	\N	\N	2026-09-19 14:57:07.179334+07	3	auto	\N	\N	\N	{}	\N	\N
11117	1047	107	f	\N	\N	2026-09-19 14:57:07.179334+07	4	auto	\N	\N	\N	{}	\N	\N
11118	1047	108	f	\N	\N	2026-09-19 14:57:07.179334+07	5	auto	\N	\N	\N	{}	\N	\N
11119	1048	147	f	\N	\N	2026-09-19 14:57:07.181136+07	1	auto	\N	\N	\N	{}	\N	\N
11120	1048	111	f	\N	\N	2026-09-19 14:57:07.181136+07	2	auto	\N	\N	\N	{}	\N	\N
11121	1048	109	f	\N	\N	2026-09-19 14:57:07.181136+07	3	auto	\N	\N	\N	{}	\N	\N
11122	1048	55	f	\N	\N	2026-09-19 14:57:07.181136+07	4	auto	\N	\N	\N	{}	\N	\N
11123	1048	75	f	\N	\N	2026-09-19 14:57:07.181136+07	5	auto	\N	\N	\N	{}	\N	\N
11134	1051	150	f	\N	\N	2026-09-19 14:57:08.963964+07	1	auto	\N	\N	\N	{}	\N	\N
11135	1051	114	f	\N	\N	2026-09-19 14:57:08.963964+07	2	auto	\N	\N	\N	{}	\N	\N
11136	1051	115	f	\N	\N	2026-09-19 14:57:08.963964+07	3	auto	\N	\N	\N	{}	\N	\N
11137	1051	15	f	\N	\N	2026-09-19 14:57:08.963964+07	4	auto	\N	\N	\N	{}	\N	\N
11138	1051	18	f	\N	\N	2026-09-19 14:57:08.963964+07	5	auto	\N	\N	\N	{}	\N	\N
11139	1052	117	f	\N	\N	2026-09-19 14:57:09.046171+07	1	auto	\N	\N	\N	{}	\N	\N
11140	1052	118	f	\N	\N	2026-09-19 14:57:09.046171+07	2	auto	\N	\N	\N	{}	\N	\N
11141	1052	119	f	\N	\N	2026-09-19 14:57:09.046171+07	3	auto	\N	\N	\N	{}	\N	\N
11142	1052	19	f	\N	\N	2026-09-19 14:57:09.046171+07	4	auto	\N	\N	\N	{}	\N	\N
11143	1052	26	f	\N	\N	2026-09-19 14:57:09.046171+07	5	auto	\N	\N	\N	{}	\N	\N
11164	1057	9	f	\N	\N	2026-09-19 14:57:09.486292+07	1	auto	\N	\N	\N	{}	\N	\N
11165	1057	135	f	\N	\N	2026-09-19 14:57:09.486292+07	2	auto	\N	\N	\N	{}	\N	\N
11166	1057	109	f	\N	\N	2026-09-19 14:57:09.486292+07	3	auto	\N	\N	\N	{}	\N	\N
11167	1057	94	f	\N	\N	2026-09-19 14:57:09.486292+07	4	auto	\N	\N	\N	{}	\N	\N
11168	1057	2	f	\N	\N	2026-09-19 14:57:09.486292+07	5	auto	\N	\N	\N	{}	\N	\N
11179	1060	113	f	\N	\N	2026-09-19 14:57:09.785254+07	1	auto	\N	\N	\N	{}	\N	\N
11180	1060	124	f	\N	\N	2026-09-19 14:57:09.785254+07	2	auto	\N	\N	\N	{}	\N	\N
11181	1060	138	f	\N	\N	2026-09-19 14:57:09.785254+07	3	auto	\N	\N	\N	{}	\N	\N
11009	1033	114	f	\N	\N	2026-09-19 14:57:06.198679+07	6	auto	\N	\N	\N	{}	\N	\N
11010	1033	115	f	\N	\N	2026-09-19 14:57:06.198679+07	7	auto	\N	\N	\N	{}	\N	\N
11011	1033	85	f	\N	\N	2026-09-19 14:57:06.198679+07	13	auto	\N	\N	\N	{}	\N	\N
11012	1033	90	f	\N	\N	2026-09-19 14:57:06.198679+07	12	auto	\N	\N	\N	{}	\N	\N
11013	1033	12	f	\N	\N	2026-09-19 14:57:06.198679+07	16	auto	\N	\N	\N	{}	\N	\N
11014	1033	49	f	\N	\N	2026-09-19 14:57:06.198679+07	17	auto	\N	\N	\N	{}	\N	\N
11015	1033	52	f	\N	\N	2026-09-19 14:57:06.198679+07	14	auto	\N	\N	\N	{}	\N	\N
11016	1033	64	f	\N	\N	2026-09-19 14:57:06.198679+07	15	auto	\N	\N	\N	{}	\N	\N
11017	1033	72	f	\N	\N	2026-09-19 14:57:06.198679+07	8	auto	\N	\N	\N	{}	\N	\N
11018	1033	76	f	\N	\N	2026-09-19 14:57:06.198679+07	9	auto	\N	\N	\N	{}	\N	\N
11019	1033	32	f	\N	\N	2026-09-19 14:57:06.198679+07	10	auto	\N	\N	\N	{}	\N	\N
11020	1033	4	f	\N	\N	2026-09-19 14:57:06.198679+07	11	auto	\N	\N	\N	{}	\N	\N
11033	1035	119	f	\N	\N	2026-09-19 14:57:06.56379+07	6	auto	\N	\N	\N	{}	\N	\N
11034	1035	121	f	\N	\N	2026-09-19 14:57:06.56379+07	7	auto	\N	\N	\N	{}	\N	\N
11035	1035	89	f	\N	\N	2026-09-19 14:57:06.56379+07	13	auto	\N	\N	\N	{}	\N	\N
11036	1035	70	f	\N	\N	2026-09-19 14:57:06.56379+07	12	auto	\N	\N	\N	{}	\N	\N
11037	1035	43	f	\N	\N	2026-09-19 14:57:06.56379+07	16	auto	\N	\N	\N	{}	\N	\N
11038	1035	45	f	\N	\N	2026-09-19 14:57:06.56379+07	17	auto	\N	\N	\N	{}	\N	\N
11039	1035	48	f	\N	\N	2026-09-19 14:57:06.56379+07	14	auto	\N	\N	\N	{}	\N	\N
11040	1035	58	f	\N	\N	2026-09-19 14:57:06.56379+07	15	auto	\N	\N	\N	{}	\N	\N
11041	1035	17	f	\N	\N	2026-09-19 14:57:06.56379+07	8	auto	\N	\N	\N	{}	\N	\N
11042	1035	60	f	\N	\N	2026-09-19 14:57:06.56379+07	9	auto	\N	\N	\N	{}	\N	\N
11043	1035	28	f	\N	\N	2026-09-19 14:57:06.56379+07	10	auto	\N	\N	\N	{}	\N	\N
11044	1035	47	f	\N	\N	2026-09-19 14:57:06.56379+07	11	auto	\N	\N	\N	{}	\N	\N
11045	1036	125	f	\N	\N	2026-09-19 14:57:06.565822+07	6	auto	\N	\N	\N	{}	\N	\N
11046	1036	126	f	\N	\N	2026-09-19 14:57:06.565822+07	7	auto	\N	\N	\N	{}	\N	\N
11047	1036	91	f	\N	\N	2026-09-19 14:57:06.565822+07	13	auto	\N	\N	\N	{}	\N	\N
11048	1036	88	f	\N	\N	2026-09-19 14:57:06.565822+07	12	auto	\N	\N	\N	{}	\N	\N
11049	1036	51	f	\N	\N	2026-09-19 14:57:06.565822+07	16	auto	\N	\N	\N	{}	\N	\N
11050	1036	53	f	\N	\N	2026-09-19 14:57:06.565822+07	17	auto	\N	\N	\N	{}	\N	\N
11051	1036	66	f	\N	\N	2026-09-19 14:57:06.565822+07	14	auto	\N	\N	\N	{}	\N	\N
11052	1036	37	f	\N	\N	2026-09-19 14:57:06.565822+07	15	auto	\N	\N	\N	{}	\N	\N
11053	1036	71	f	\N	\N	2026-09-19 14:57:06.565822+07	8	auto	\N	\N	\N	{}	\N	\N
11054	1036	55	f	\N	\N	2026-09-19 14:57:06.565822+07	9	auto	\N	\N	\N	{}	\N	\N
11055	1036	78	f	\N	\N	2026-09-19 14:57:06.565822+07	10	auto	\N	\N	\N	{}	\N	\N
11056	1036	42	f	\N	\N	2026-09-19 14:57:06.565822+07	11	auto	\N	\N	\N	{}	\N	\N
11174	1059	123	f	\N	\N	2026-09-19 14:57:09.658697+07	1	auto	\N	\N	\N	{}	\N	\N
11175	1059	137	f	\N	\N	2026-09-19 14:57:09.658697+07	2	auto	\N	\N	\N	{}	\N	\N
11176	1059	99	f	\N	\N	2026-09-19 14:57:09.658697+07	3	auto	\N	\N	\N	{}	\N	\N
11177	1059	7	f	\N	\N	2026-09-19 14:57:09.658697+07	4	auto	\N	\N	\N	{}	\N	\N
11178	1059	14	f	\N	\N	2026-09-19 14:57:09.658697+07	5	auto	\N	\N	\N	{}	\N	\N
11194	1063	117	f	\N	\N	2026-09-19 14:57:10.017623+07	1	auto	\N	\N	\N	{}	\N	\N
11195	1063	118	f	\N	\N	2026-09-19 14:57:10.017623+07	2	auto	\N	\N	\N	{}	\N	\N
11196	1063	119	f	\N	\N	2026-09-19 14:57:10.017623+07	3	auto	\N	\N	\N	{}	\N	\N
11197	1063	105	f	\N	\N	2026-09-19 14:57:10.017623+07	4	auto	\N	\N	\N	{}	\N	\N
11198	1063	39	f	\N	\N	2026-09-19 14:57:10.017623+07	5	auto	\N	\N	\N	{}	\N	\N
11124	1049	148	f	\N	\N	2026-09-19 14:57:08.801624+07	1	auto	\N	\N	\N	{}	\N	\N
11125	1049	112	f	\N	\N	2026-09-19 14:57:08.801624+07	2	auto	\N	\N	\N	{}	\N	\N
11126	1049	123	f	\N	\N	2026-09-19 14:57:08.801624+07	3	auto	\N	\N	\N	{}	\N	\N
11127	1049	2	f	\N	\N	2026-09-19 14:57:08.801624+07	4	auto	\N	\N	\N	{}	\N	\N
11128	1049	6	f	\N	\N	2026-09-19 14:57:08.801624+07	5	auto	\N	\N	\N	{}	\N	\N
11159	1056	133	f	\N	\N	2026-09-19 14:57:09.401198+07	1	auto	\N	\N	\N	{}	\N	\N
11160	1056	34	f	\N	\N	2026-09-19 14:57:09.401198+07	2	auto	\N	\N	\N	{}	\N	\N
11161	1056	107	f	\N	\N	2026-09-19 14:57:09.401198+07	3	auto	\N	\N	\N	{}	\N	\N
11162	1056	108	f	\N	\N	2026-09-19 14:57:09.401198+07	4	auto	\N	\N	\N	{}	\N	\N
11163	1056	95	f	\N	\N	2026-09-19 14:57:09.401198+07	5	auto	\N	\N	\N	{}	\N	\N
11199	1064	143	f	\N	\N	2026-09-19 14:57:10.10137+07	1	auto	\N	\N	\N	{}	\N	\N
11200	1064	121	f	\N	\N	2026-09-19 14:57:10.10137+07	2	auto	\N	\N	\N	{}	\N	\N
11201	1064	125	f	\N	\N	2026-09-19 14:57:10.10137+07	3	auto	\N	\N	\N	{}	\N	\N
11202	1064	106	f	\N	\N	2026-09-19 14:57:10.10137+07	4	auto	\N	\N	\N	{}	\N	\N
11203	1064	93	f	\N	\N	2026-09-19 14:57:10.10137+07	5	auto	\N	\N	\N	{}	\N	\N
11182	1060	15	f	\N	\N	2026-09-19 14:57:09.785254+07	4	auto	\N	\N	\N	{}	\N	\N
11183	1060	18	f	\N	\N	2026-09-19 14:57:09.785254+07	5	auto	\N	\N	\N	{}	\N	\N
11184	1061	114	f	\N	\N	2026-09-19 14:57:09.786341+07	1	auto	\N	\N	\N	{}	\N	\N
11185	1061	139	f	\N	\N	2026-09-19 14:57:09.786341+07	2	auto	\N	\N	\N	{}	\N	\N
11186	1061	101	f	\N	\N	2026-09-19 14:57:09.786341+07	3	auto	\N	\N	\N	{}	\N	\N
11187	1061	19	f	\N	\N	2026-09-19 14:57:09.786341+07	4	auto	\N	\N	\N	{}	\N	\N
11188	1061	26	f	\N	\N	2026-09-19 14:57:09.786341+07	5	auto	\N	\N	\N	{}	\N	\N
11189	1062	115	f	\N	\N	2026-09-19 14:57:09.787276+07	1	auto	\N	\N	\N	{}	\N	\N
11190	1062	142	f	\N	\N	2026-09-19 14:57:09.787276+07	2	auto	\N	\N	\N	{}	\N	\N
11191	1062	103	f	\N	\N	2026-09-19 14:57:09.787276+07	3	auto	\N	\N	\N	{}	\N	\N
11192	1062	27	f	\N	\N	2026-09-19 14:57:09.787276+07	4	auto	\N	\N	\N	{}	\N	\N
11193	1062	38	f	\N	\N	2026-09-19 14:57:09.787276+07	5	auto	\N	\N	\N	{}	\N	\N
11204	1065	126	f	\N	\N	2026-09-19 14:57:10.188203+07	1	auto	\N	\N	\N	{}	\N	\N
11205	1065	127	f	\N	\N	2026-09-19 14:57:10.188203+07	2	auto	\N	\N	\N	{}	\N	\N
11206	1065	129	f	\N	\N	2026-09-19 14:57:10.188203+07	3	auto	\N	\N	\N	{}	\N	\N
11207	1065	8	f	\N	\N	2026-09-19 14:57:10.188203+07	4	auto	\N	\N	\N	{}	\N	\N
11208	1065	96	f	\N	\N	2026-09-19 14:57:10.188203+07	5	auto	\N	\N	\N	{}	\N	\N
11934	1128	22	f	\N	\N	2026-09-19 15:01:44.195095+07	6	auto	\N	\N	\N	{}	\N	\N
11935	1128	94	f	\N	\N	2026-09-19 15:01:44.195095+07	7	auto	\N	\N	\N	{}	\N	\N
11936	1128	71	f	\N	\N	2026-09-19 15:01:44.195095+07	13	auto	\N	\N	\N	{}	\N	\N
11937	1128	70	f	\N	\N	2026-09-19 15:01:44.195095+07	12	auto	\N	\N	\N	{}	\N	\N
11938	1128	41	f	\N	\N	2026-09-19 15:01:44.195095+07	16	auto	\N	\N	\N	{}	\N	\N
11939	1128	43	f	\N	\N	2026-09-19 15:01:44.195095+07	17	auto	\N	\N	\N	{}	\N	\N
11940	1128	46	f	\N	\N	2026-09-19 15:01:44.195095+07	14	auto	\N	\N	\N	{}	\N	\N
11941	1128	48	f	\N	\N	2026-09-19 15:01:44.195095+07	15	auto	\N	\N	\N	{}	\N	\N
11942	1128	72	f	\N	\N	2026-09-19 15:01:44.195095+07	8	auto	\N	\N	\N	{}	\N	\N
11943	1128	52	f	\N	\N	2026-09-19 15:01:44.195095+07	9	auto	\N	\N	\N	{}	\N	\N
11944	1128	73	f	\N	\N	2026-09-19 15:01:44.195095+07	10	auto	\N	\N	\N	{}	\N	\N
11945	1128	45	f	\N	\N	2026-09-19 15:01:44.195095+07	11	auto	\N	\N	\N	{}	\N	\N
11946	1129	34	f	\N	\N	2026-09-19 15:01:44.198682+07	6	auto	\N	\N	\N	{}	\N	\N
11947	1129	97	f	\N	\N	2026-09-19 15:01:44.198682+07	7	auto	\N	\N	\N	{}	\N	\N
11948	1129	75	f	\N	\N	2026-09-19 15:01:44.198682+07	13	auto	\N	\N	\N	{}	\N	\N
11949	1129	76	f	\N	\N	2026-09-19 15:01:44.198682+07	12	auto	\N	\N	\N	{}	\N	\N
11950	1129	47	f	\N	\N	2026-09-19 15:01:44.198682+07	16	auto	\N	\N	\N	{}	\N	\N
11951	1129	51	f	\N	\N	2026-09-19 15:01:44.198682+07	17	auto	\N	\N	\N	{}	\N	\N
11952	1129	54	f	\N	\N	2026-09-19 15:01:44.198682+07	14	auto	\N	\N	\N	{}	\N	\N
11953	1129	58	f	\N	\N	2026-09-19 15:01:44.198682+07	15	auto	\N	\N	\N	{}	\N	\N
11954	1129	77	f	\N	\N	2026-09-19 15:01:44.198682+07	8	auto	\N	\N	\N	{}	\N	\N
11955	1129	53	f	\N	\N	2026-09-19 15:01:44.198682+07	9	auto	\N	\N	\N	{}	\N	\N
11956	1129	82	f	\N	\N	2026-09-19 15:01:44.198682+07	10	auto	\N	\N	\N	{}	\N	\N
11957	1129	60	f	\N	\N	2026-09-19 15:01:44.198682+07	11	auto	\N	\N	\N	{}	\N	\N
11958	1130	35	f	\N	\N	2026-09-19 15:01:44.470632+07	6	auto	\N	\N	\N	{}	\N	\N
11959	1130	99	f	\N	\N	2026-09-19 15:01:44.470632+07	7	auto	\N	\N	\N	{}	\N	\N
11960	1130	83	f	\N	\N	2026-09-19 15:01:44.470632+07	13	auto	\N	\N	\N	{}	\N	\N
11961	1130	88	f	\N	\N	2026-09-19 15:01:44.470632+07	12	auto	\N	\N	\N	{}	\N	\N
11962	1130	55	f	\N	\N	2026-09-19 15:01:44.470632+07	16	auto	\N	\N	\N	{}	\N	\N
11963	1130	57	f	\N	\N	2026-09-19 15:01:44.470632+07	17	auto	\N	\N	\N	{}	\N	\N
11964	1130	64	f	\N	\N	2026-09-19 15:01:44.470632+07	14	auto	\N	\N	\N	{}	\N	\N
11965	1130	66	f	\N	\N	2026-09-19 15:01:44.470632+07	15	auto	\N	\N	\N	{}	\N	\N
11966	1130	90	f	\N	\N	2026-09-19 15:01:44.470632+07	8	auto	\N	\N	\N	{}	\N	\N
11967	1130	84	f	\N	\N	2026-09-19 15:01:44.470632+07	9	auto	\N	\N	\N	{}	\N	\N
11968	1130	85	f	\N	\N	2026-09-19 15:01:44.470632+07	10	auto	\N	\N	\N	{}	\N	\N
11969	1130	61	f	\N	\N	2026-09-19 15:01:44.470632+07	11	auto	\N	\N	\N	{}	\N	\N
11970	1131	101	f	\N	\N	2026-09-19 15:01:44.632741+07	6	auto	\N	\N	\N	{}	\N	\N
11971	1131	103	f	\N	\N	2026-09-19 15:01:44.632741+07	7	auto	\N	\N	\N	{}	\N	\N
11972	1131	87	f	\N	\N	2026-09-19 15:01:44.632741+07	13	auto	\N	\N	\N	{}	\N	\N
11973	1131	29	f	\N	\N	2026-09-19 15:01:44.632741+07	12	auto	\N	\N	\N	{}	\N	\N
11974	1131	63	f	\N	\N	2026-09-19 15:01:44.632741+07	16	auto	\N	\N	\N	{}	\N	\N
11975	1131	65	f	\N	\N	2026-09-19 15:01:44.632741+07	17	auto	\N	\N	\N	{}	\N	\N
11976	1131	78	f	\N	\N	2026-09-19 15:01:44.632741+07	14	auto	\N	\N	\N	{}	\N	\N
11977	1131	25	f	\N	\N	2026-09-19 15:01:44.632741+07	15	auto	\N	\N	\N	{}	\N	\N
11978	1131	89	f	\N	\N	2026-09-19 15:01:44.632741+07	8	auto	\N	\N	\N	{}	\N	\N
11979	1131	67	f	\N	\N	2026-09-19 15:01:44.632741+07	9	auto	\N	\N	\N	{}	\N	\N
11980	1131	5	f	\N	\N	2026-09-19 15:01:44.632741+07	10	auto	\N	\N	\N	{}	\N	\N
11981	1131	17	f	\N	\N	2026-09-19 15:01:44.632741+07	11	auto	\N	\N	\N	{}	\N	\N
11982	1132	105	f	\N	\N	2026-09-19 15:01:44.696335+07	6	auto	\N	\N	\N	{}	\N	\N
11983	1132	106	f	\N	\N	2026-09-19 15:01:44.696335+07	7	auto	\N	\N	\N	{}	\N	\N
11984	1132	91	f	\N	\N	2026-09-19 15:01:44.696335+07	13	auto	\N	\N	\N	{}	\N	\N
11985	1132	70	f	\N	\N	2026-09-19 15:01:44.696335+07	12	auto	\N	\N	\N	{}	\N	\N
11986	1132	69	f	\N	\N	2026-09-19 15:01:44.696335+07	16	auto	\N	\N	\N	{}	\N	\N
11987	1132	36	f	\N	\N	2026-09-19 15:01:44.696335+07	17	auto	\N	\N	\N	{}	\N	\N
11988	1132	37	f	\N	\N	2026-09-19 15:01:44.696335+07	14	auto	\N	\N	\N	{}	\N	\N
11989	1132	42	f	\N	\N	2026-09-19 15:01:44.696335+07	15	auto	\N	\N	\N	{}	\N	\N
11990	1132	72	f	\N	\N	2026-09-19 15:01:44.696335+07	8	auto	\N	\N	\N	{}	\N	\N
11991	1132	46	f	\N	\N	2026-09-19 15:01:44.696335+07	9	auto	\N	\N	\N	{}	\N	\N
11992	1132	81	f	\N	\N	2026-09-19 15:01:44.696335+07	10	auto	\N	\N	\N	{}	\N	\N
11993	1132	49	f	\N	\N	2026-09-19 15:01:44.696335+07	11	auto	\N	\N	\N	{}	\N	\N
11994	1133	32	f	\N	\N	2026-09-19 15:01:44.898832+07	6	auto	\N	\N	\N	{}	\N	\N
11995	1133	93	f	\N	\N	2026-09-19 15:01:44.898832+07	7	auto	\N	\N	\N	{}	\N	\N
11996	1133	4	f	\N	\N	2026-09-19 15:01:44.898832+07	13	auto	\N	\N	\N	{}	\N	\N
11997	1133	76	f	\N	\N	2026-09-19 15:01:44.898832+07	12	auto	\N	\N	\N	{}	\N	\N
11998	1133	12	f	\N	\N	2026-09-19 15:01:44.898832+07	16	auto	\N	\N	\N	{}	\N	\N
11999	1133	24	f	\N	\N	2026-09-19 15:01:44.898832+07	17	auto	\N	\N	\N	{}	\N	\N
12000	1133	48	f	\N	\N	2026-09-19 15:01:44.898832+07	14	auto	\N	\N	\N	{}	\N	\N
12001	1133	52	f	\N	\N	2026-09-19 15:01:44.898832+07	15	auto	\N	\N	\N	{}	\N	\N
12002	1133	16	f	\N	\N	2026-09-19 15:01:44.898832+07	8	auto	\N	\N	\N	{}	\N	\N
12003	1133	28	f	\N	\N	2026-09-19 15:01:44.898832+07	9	auto	\N	\N	\N	{}	\N	\N
12004	1133	82	f	\N	\N	2026-09-19 15:01:44.898832+07	10	auto	\N	\N	\N	{}	\N	\N
12005	1133	54	f	\N	\N	2026-09-19 15:01:44.898832+07	11	auto	\N	\N	\N	{}	\N	\N
12006	1134	96	f	\N	\N	2026-09-19 15:01:45.084546+07	6	auto	\N	\N	\N	{}	\N	\N
12007	1134	102	f	\N	\N	2026-09-19 15:01:45.084546+07	7	auto	\N	\N	\N	{}	\N	\N
12008	1134	71	f	\N	\N	2026-09-19 15:01:45.084546+07	13	auto	\N	\N	\N	{}	\N	\N
12009	1134	88	f	\N	\N	2026-09-19 15:01:45.084546+07	12	auto	\N	\N	\N	{}	\N	\N
12010	1134	41	f	\N	\N	2026-09-19 15:01:45.084546+07	16	auto	\N	\N	\N	{}	\N	\N
12011	1134	43	f	\N	\N	2026-09-19 15:01:45.084546+07	17	auto	\N	\N	\N	{}	\N	\N
12012	1134	58	f	\N	\N	2026-09-19 15:01:45.084546+07	14	auto	\N	\N	\N	{}	\N	\N
12013	1134	60	f	\N	\N	2026-09-19 15:01:45.084546+07	15	auto	\N	\N	\N	{}	\N	\N
12014	1134	84	f	\N	\N	2026-09-19 15:01:45.084546+07	8	auto	\N	\N	\N	{}	\N	\N
12015	1134	64	f	\N	\N	2026-09-19 15:01:45.084546+07	9	auto	\N	\N	\N	{}	\N	\N
12016	1134	73	f	\N	\N	2026-09-19 15:01:45.084546+07	10	auto	\N	\N	\N	{}	\N	\N
12017	1134	45	f	\N	\N	2026-09-19 15:01:45.084546+07	11	auto	\N	\N	\N	{}	\N	\N
12018	1135	95	f	\N	\N	2026-09-19 15:01:45.092841+07	6	auto	\N	\N	\N	{}	\N	\N
12019	1135	107	f	\N	\N	2026-09-19 15:01:45.092841+07	7	auto	\N	\N	\N	{}	\N	\N
12020	1135	75	f	\N	\N	2026-09-19 15:01:45.092841+07	13	auto	\N	\N	\N	{}	\N	\N
12021	1135	90	f	\N	\N	2026-09-19 15:01:45.092841+07	12	auto	\N	\N	\N	{}	\N	\N
12022	1135	47	f	\N	\N	2026-09-19 15:01:45.092841+07	16	auto	\N	\N	\N	{}	\N	\N
12023	1135	51	f	\N	\N	2026-09-19 15:01:45.092841+07	17	auto	\N	\N	\N	{}	\N	\N
12024	1135	66	f	\N	\N	2026-09-19 15:01:45.092841+07	14	auto	\N	\N	\N	{}	\N	\N
12025	1135	25	f	\N	\N	2026-09-19 15:01:45.092841+07	15	auto	\N	\N	\N	{}	\N	\N
12026	1135	77	f	\N	\N	2026-09-19 15:01:45.092841+07	8	auto	\N	\N	\N	{}	\N	\N
12027	1135	53	f	\N	\N	2026-09-19 15:01:45.092841+07	9	auto	\N	\N	\N	{}	\N	\N
12028	1135	29	f	\N	\N	2026-09-19 15:01:45.092841+07	10	auto	\N	\N	\N	{}	\N	\N
12029	1135	78	f	\N	\N	2026-09-19 15:01:45.092841+07	11	auto	\N	\N	\N	{}	\N	\N
12030	1136	108	f	\N	\N	2026-09-19 15:01:45.094135+07	6	auto	\N	\N	\N	{}	\N	\N
12031	1136	109	f	\N	\N	2026-09-19 15:01:45.094135+07	7	auto	\N	\N	\N	{}	\N	\N
12032	1136	83	f	\N	\N	2026-09-19 15:01:45.094135+07	13	auto	\N	\N	\N	{}	\N	\N
12033	1136	5	f	\N	\N	2026-09-19 15:01:45.094135+07	12	auto	\N	\N	\N	{}	\N	\N
12034	1136	55	f	\N	\N	2026-09-19 15:01:45.094135+07	16	auto	\N	\N	\N	{}	\N	\N
12035	1136	57	f	\N	\N	2026-09-19 15:01:45.094135+07	17	auto	\N	\N	\N	{}	\N	\N
12036	1136	37	f	\N	\N	2026-09-19 15:01:45.094135+07	14	auto	\N	\N	\N	{}	\N	\N
12037	1136	42	f	\N	\N	2026-09-19 15:01:45.094135+07	15	auto	\N	\N	\N	{}	\N	\N
12038	1136	17	f	\N	\N	2026-09-19 15:01:45.094135+07	8	auto	\N	\N	\N	{}	\N	\N
12039	1136	46	f	\N	\N	2026-09-19 15:01:45.094135+07	9	auto	\N	\N	\N	{}	\N	\N
12040	1136	85	f	\N	\N	2026-09-19 15:01:45.094135+07	10	auto	\N	\N	\N	{}	\N	\N
12041	1136	61	f	\N	\N	2026-09-19 15:01:45.094135+07	11	auto	\N	\N	\N	{}	\N	\N
12306	1159	150	f	\N	\N	2026-09-19 15:01:48.465312+07	6	auto	\N	\N	\N	{}	\N	\N
12307	1159	108	f	\N	\N	2026-09-19 15:01:48.465312+07	7	auto	\N	\N	\N	{}	\N	\N
12308	1159	77	f	\N	\N	2026-09-19 15:01:48.465312+07	13	auto	\N	\N	\N	{}	\N	\N
12309	1159	90	f	\N	\N	2026-09-19 15:01:48.465312+07	12	auto	\N	\N	\N	{}	\N	\N
12310	1159	36	f	\N	\N	2026-09-19 15:01:48.465312+07	16	auto	\N	\N	\N	{}	\N	\N
12311	1159	65	f	\N	\N	2026-09-19 15:01:48.465312+07	17	auto	\N	\N	\N	{}	\N	\N
12312	1159	25	f	\N	\N	2026-09-19 15:01:48.465312+07	14	auto	\N	\N	\N	{}	\N	\N
12313	1159	46	f	\N	\N	2026-09-19 15:01:48.465312+07	15	auto	\N	\N	\N	{}	\N	\N
12314	1159	81	f	\N	\N	2026-09-19 15:01:48.465312+07	8	auto	\N	\N	\N	{}	\N	\N
12315	1159	67	f	\N	\N	2026-09-19 15:01:48.465312+07	9	auto	\N	\N	\N	{}	\N	\N
12316	1159	76	f	\N	\N	2026-09-19 15:01:48.465312+07	10	auto	\N	\N	\N	{}	\N	\N
12317	1159	29	f	\N	\N	2026-09-19 15:01:48.465312+07	11	auto	\N	\N	\N	{}	\N	\N
12426	1169	124	f	\N	\N	2026-09-19 15:01:50.084038+07	6	auto	\N	\N	\N	{}	\N	\N
12427	1169	8	f	\N	\N	2026-09-19 15:01:50.084038+07	7	auto	\N	\N	\N	{}	\N	\N
12428	1169	71	f	\N	\N	2026-09-19 15:01:50.084038+07	13	auto	\N	\N	\N	{}	\N	\N
12429	1169	29	f	\N	\N	2026-09-19 15:01:50.084038+07	12	auto	\N	\N	\N	{}	\N	\N
12430	1169	47	f	\N	\N	2026-09-19 15:01:50.084038+07	16	auto	\N	\N	\N	{}	\N	\N
12431	1169	51	f	\N	\N	2026-09-19 15:01:50.084038+07	17	auto	\N	\N	\N	{}	\N	\N
12432	1169	46	f	\N	\N	2026-09-19 15:01:50.084038+07	14	auto	\N	\N	\N	{}	\N	\N
12433	1169	48	f	\N	\N	2026-09-19 15:01:50.084038+07	15	auto	\N	\N	\N	{}	\N	\N
12434	1169	91	f	\N	\N	2026-09-19 15:01:50.084038+07	8	auto	\N	\N	\N	{}	\N	\N
12435	1169	53	f	\N	\N	2026-09-19 15:01:50.084038+07	9	auto	\N	\N	\N	{}	\N	\N
12436	1169	5	f	\N	\N	2026-09-19 15:01:50.084038+07	10	auto	\N	\N	\N	{}	\N	\N
12437	1169	66	f	\N	\N	2026-09-19 15:01:50.084038+07	11	auto	\N	\N	\N	{}	\N	\N
12438	1170	127	f	\N	\N	2026-09-19 15:01:50.325882+07	6	auto	\N	\N	\N	{}	\N	\N
12439	1170	129	f	\N	\N	2026-09-19 15:01:50.325882+07	7	auto	\N	\N	\N	{}	\N	\N
12440	1170	73	f	\N	\N	2026-09-19 15:01:50.325882+07	13	auto	\N	\N	\N	{}	\N	\N
12441	1170	70	f	\N	\N	2026-09-19 15:01:50.325882+07	12	auto	\N	\N	\N	{}	\N	\N
12442	1170	55	f	\N	\N	2026-09-19 15:01:50.325882+07	16	auto	\N	\N	\N	{}	\N	\N
12443	1170	57	f	\N	\N	2026-09-19 15:01:50.325882+07	17	auto	\N	\N	\N	{}	\N	\N
12444	1170	58	f	\N	\N	2026-09-19 15:01:50.325882+07	14	auto	\N	\N	\N	{}	\N	\N
12445	1170	54	f	\N	\N	2026-09-19 15:01:50.325882+07	15	auto	\N	\N	\N	{}	\N	\N
12446	1170	78	f	\N	\N	2026-09-19 15:01:50.325882+07	8	auto	\N	\N	\N	{}	\N	\N
12447	1170	88	f	\N	\N	2026-09-19 15:01:50.325882+07	9	auto	\N	\N	\N	{}	\N	\N
12448	1170	75	f	\N	\N	2026-09-19 15:01:50.325882+07	10	auto	\N	\N	\N	{}	\N	\N
12449	1170	61	f	\N	\N	2026-09-19 15:01:50.325882+07	11	auto	\N	\N	\N	{}	\N	\N
12450	1171	115	f	\N	\N	2026-09-19 15:01:50.333946+07	6	auto	\N	\N	\N	{}	\N	\N
12451	1171	114	f	\N	\N	2026-09-19 15:01:50.333946+07	7	auto	\N	\N	\N	{}	\N	\N
12452	1171	77	f	\N	\N	2026-09-19 15:01:50.333946+07	13	auto	\N	\N	\N	{}	\N	\N
12453	1171	72	f	\N	\N	2026-09-19 15:01:50.333946+07	12	auto	\N	\N	\N	{}	\N	\N
12454	1171	63	f	\N	\N	2026-09-19 15:01:50.333946+07	16	auto	\N	\N	\N	{}	\N	\N
12455	1171	36	f	\N	\N	2026-09-19 15:01:50.333946+07	17	auto	\N	\N	\N	{}	\N	\N
12456	1171	52	f	\N	\N	2026-09-19 15:01:50.333946+07	14	auto	\N	\N	\N	{}	\N	\N
12457	1171	42	f	\N	\N	2026-09-19 15:01:50.333946+07	15	auto	\N	\N	\N	{}	\N	\N
12458	1171	83	f	\N	\N	2026-09-19 15:01:50.333946+07	8	auto	\N	\N	\N	{}	\N	\N
12459	1171	65	f	\N	\N	2026-09-19 15:01:50.333946+07	9	auto	\N	\N	\N	{}	\N	\N
12460	1171	82	f	\N	\N	2026-09-19 15:01:50.333946+07	10	auto	\N	\N	\N	{}	\N	\N
12461	1171	37	f	\N	\N	2026-09-19 15:01:50.333946+07	11	auto	\N	\N	\N	{}	\N	\N
12462	1172	96	f	\N	\N	2026-09-19 15:01:50.335527+07	6	auto	\N	\N	\N	{}	\N	\N
12463	1172	94	f	\N	\N	2026-09-19 15:01:50.335527+07	7	auto	\N	\N	\N	{}	\N	\N
12464	1172	85	f	\N	\N	2026-09-19 15:01:50.335527+07	13	auto	\N	\N	\N	{}	\N	\N
12465	1172	76	f	\N	\N	2026-09-19 15:01:50.335527+07	12	auto	\N	\N	\N	{}	\N	\N
12466	1172	67	f	\N	\N	2026-09-19 15:01:50.335527+07	16	auto	\N	\N	\N	{}	\N	\N
12467	1172	12	f	\N	\N	2026-09-19 15:01:50.335527+07	17	auto	\N	\N	\N	{}	\N	\N
12468	1172	64	f	\N	\N	2026-09-19 15:01:50.335527+07	14	auto	\N	\N	\N	{}	\N	\N
12469	1172	25	f	\N	\N	2026-09-19 15:01:50.335527+07	15	auto	\N	\N	\N	{}	\N	\N
12470	1172	84	f	\N	\N	2026-09-19 15:01:50.335527+07	8	auto	\N	\N	\N	{}	\N	\N
12471	1172	90	f	\N	\N	2026-09-19 15:01:50.335527+07	9	auto	\N	\N	\N	{}	\N	\N
12472	1172	81	f	\N	\N	2026-09-19 15:01:50.335527+07	10	auto	\N	\N	\N	{}	\N	\N
12473	1172	49	f	\N	\N	2026-09-19 15:01:50.335527+07	11	auto	\N	\N	\N	{}	\N	\N
12606	1184	148	f	\N	\N	2026-09-19 15:01:52.781038+07	6	auto	\N	\N	\N	{}	\N	\N
12607	1184	109	f	\N	\N	2026-09-19 15:01:52.781038+07	7	auto	\N	\N	\N	{}	\N	\N
12042	1137	111	f	\N	\N	2026-09-19 15:01:45.454836+07	6	auto	\N	\N	\N	{}	\N	\N
12043	1137	112	f	\N	\N	2026-09-19 15:01:45.454836+07	7	auto	\N	\N	\N	{}	\N	\N
12044	1137	87	f	\N	\N	2026-09-19 15:01:45.454836+07	13	auto	\N	\N	\N	{}	\N	\N
12045	1137	70	f	\N	\N	2026-09-19 15:01:45.454836+07	12	auto	\N	\N	\N	{}	\N	\N
12046	1137	63	f	\N	\N	2026-09-19 15:01:45.454836+07	16	auto	\N	\N	\N	{}	\N	\N
12047	1137	65	f	\N	\N	2026-09-19 15:01:45.454836+07	17	auto	\N	\N	\N	{}	\N	\N
12048	1137	54	f	\N	\N	2026-09-19 15:01:45.454836+07	14	auto	\N	\N	\N	{}	\N	\N
12049	1137	48	f	\N	\N	2026-09-19 15:01:45.454836+07	15	auto	\N	\N	\N	{}	\N	\N
12050	1137	89	f	\N	\N	2026-09-19 15:01:45.454836+07	8	auto	\N	\N	\N	{}	\N	\N
12051	1137	67	f	\N	\N	2026-09-19 15:01:45.454836+07	9	auto	\N	\N	\N	{}	\N	\N
12052	1137	72	f	\N	\N	2026-09-19 15:01:45.454836+07	10	auto	\N	\N	\N	{}	\N	\N
12053	1137	76	f	\N	\N	2026-09-19 15:01:45.454836+07	11	auto	\N	\N	\N	{}	\N	\N
12054	1138	113	f	\N	\N	2026-09-19 15:01:45.559636+07	6	auto	\N	\N	\N	{}	\N	\N
12055	1138	114	f	\N	\N	2026-09-19 15:01:45.559636+07	7	auto	\N	\N	\N	{}	\N	\N
12056	1138	91	f	\N	\N	2026-09-19 15:01:45.559636+07	13	auto	\N	\N	\N	{}	\N	\N
12057	1138	82	f	\N	\N	2026-09-19 15:01:45.559636+07	12	auto	\N	\N	\N	{}	\N	\N
12058	1138	36	f	\N	\N	2026-09-19 15:01:45.559636+07	16	auto	\N	\N	\N	{}	\N	\N
12059	1138	49	f	\N	\N	2026-09-19 15:01:45.559636+07	17	auto	\N	\N	\N	{}	\N	\N
12060	1138	52	f	\N	\N	2026-09-19 15:01:45.559636+07	14	auto	\N	\N	\N	{}	\N	\N
12061	1138	58	f	\N	\N	2026-09-19 15:01:45.559636+07	15	auto	\N	\N	\N	{}	\N	\N
12062	1138	84	f	\N	\N	2026-09-19 15:01:45.559636+07	8	auto	\N	\N	\N	{}	\N	\N
12063	1138	60	f	\N	\N	2026-09-19 15:01:45.559636+07	9	auto	\N	\N	\N	{}	\N	\N
12064	1138	81	f	\N	\N	2026-09-19 15:01:45.559636+07	10	auto	\N	\N	\N	{}	\N	\N
12065	1138	69	f	\N	\N	2026-09-19 15:01:45.559636+07	11	auto	\N	\N	\N	{}	\N	\N
12066	1139	115	f	\N	\N	2026-09-19 15:01:45.66162+07	6	auto	\N	\N	\N	{}	\N	\N
12067	1139	117	f	\N	\N	2026-09-19 15:01:45.66162+07	7	auto	\N	\N	\N	{}	\N	\N
12068	1139	4	f	\N	\N	2026-09-19 15:01:45.66162+07	13	auto	\N	\N	\N	{}	\N	\N
12069	1139	88	f	\N	\N	2026-09-19 15:01:45.66162+07	12	auto	\N	\N	\N	{}	\N	\N
12070	1139	12	f	\N	\N	2026-09-19 15:01:45.66162+07	16	auto	\N	\N	\N	{}	\N	\N
12071	1139	24	f	\N	\N	2026-09-19 15:01:45.66162+07	17	auto	\N	\N	\N	{}	\N	\N
12072	1139	64	f	\N	\N	2026-09-19 15:01:45.66162+07	14	auto	\N	\N	\N	{}	\N	\N
12073	1139	66	f	\N	\N	2026-09-19 15:01:45.66162+07	15	auto	\N	\N	\N	{}	\N	\N
12074	1139	16	f	\N	\N	2026-09-19 15:01:45.66162+07	8	auto	\N	\N	\N	{}	\N	\N
12075	1139	28	f	\N	\N	2026-09-19 15:01:45.66162+07	9	auto	\N	\N	\N	{}	\N	\N
12076	1139	90	f	\N	\N	2026-09-19 15:01:45.66162+07	10	auto	\N	\N	\N	{}	\N	\N
12077	1139	29	f	\N	\N	2026-09-19 15:01:45.66162+07	11	auto	\N	\N	\N	{}	\N	\N
12126	1144	129	f	\N	\N	2026-09-19 15:01:46.351324+07	6	auto	\N	\N	\N	{}	\N	\N
12127	1144	130	f	\N	\N	2026-09-19 15:01:46.351324+07	7	auto	\N	\N	\N	{}	\N	\N
12128	1144	32	f	\N	\N	2026-09-19 15:01:46.351324+07	13	auto	\N	\N	\N	{}	\N	\N
12129	1144	90	f	\N	\N	2026-09-19 15:01:46.351324+07	12	auto	\N	\N	\N	{}	\N	\N
12130	1144	36	f	\N	\N	2026-09-19 15:01:46.351324+07	16	auto	\N	\N	\N	{}	\N	\N
12131	1144	49	f	\N	\N	2026-09-19 15:01:46.351324+07	17	auto	\N	\N	\N	{}	\N	\N
12132	1144	37	f	\N	\N	2026-09-19 15:01:46.351324+07	14	auto	\N	\N	\N	{}	\N	\N
12133	1144	42	f	\N	\N	2026-09-19 15:01:46.351324+07	15	auto	\N	\N	\N	{}	\N	\N
12134	1144	29	f	\N	\N	2026-09-19 15:01:46.351324+07	8	auto	\N	\N	\N	{}	\N	\N
12135	1144	78	f	\N	\N	2026-09-19 15:01:46.351324+07	9	auto	\N	\N	\N	{}	\N	\N
12136	1144	81	f	\N	\N	2026-09-19 15:01:46.351324+07	10	auto	\N	\N	\N	{}	\N	\N
12137	1144	69	f	\N	\N	2026-09-19 15:01:46.351324+07	11	auto	\N	\N	\N	{}	\N	\N
12138	1145	131	f	\N	\N	2026-09-19 15:01:46.458462+07	6	auto	\N	\N	\N	{}	\N	\N
12139	1145	132	f	\N	\N	2026-09-19 15:01:46.458462+07	7	auto	\N	\N	\N	{}	\N	\N
12140	1145	91	f	\N	\N	2026-09-19 15:01:46.458462+07	13	auto	\N	\N	\N	{}	\N	\N
12141	1145	5	f	\N	\N	2026-09-19 15:01:46.458462+07	12	auto	\N	\N	\N	{}	\N	\N
12142	1145	12	f	\N	\N	2026-09-19 15:01:46.458462+07	16	auto	\N	\N	\N	{}	\N	\N
12143	1145	24	f	\N	\N	2026-09-19 15:01:46.458462+07	17	auto	\N	\N	\N	{}	\N	\N
12144	1145	25	f	\N	\N	2026-09-19 15:01:46.458462+07	14	auto	\N	\N	\N	{}	\N	\N
12145	1145	54	f	\N	\N	2026-09-19 15:01:46.458462+07	15	auto	\N	\N	\N	{}	\N	\N
12146	1145	4	f	\N	\N	2026-09-19 15:01:46.458462+07	8	auto	\N	\N	\N	{}	\N	\N
12147	1145	16	f	\N	\N	2026-09-19 15:01:46.458462+07	9	auto	\N	\N	\N	{}	\N	\N
12148	1145	76	f	\N	\N	2026-09-19 15:01:46.458462+07	10	auto	\N	\N	\N	{}	\N	\N
12149	1145	46	f	\N	\N	2026-09-19 15:01:46.458462+07	11	auto	\N	\N	\N	{}	\N	\N
12150	1146	133	f	\N	\N	2026-09-19 15:01:46.558406+07	6	auto	\N	\N	\N	{}	\N	\N
12151	1146	135	f	\N	\N	2026-09-19 15:01:46.558406+07	7	auto	\N	\N	\N	{}	\N	\N
12152	1146	28	f	\N	\N	2026-09-19 15:01:46.558406+07	13	auto	\N	\N	\N	{}	\N	\N
12153	1146	17	f	\N	\N	2026-09-19 15:01:46.558406+07	12	auto	\N	\N	\N	{}	\N	\N
12154	1146	41	f	\N	\N	2026-09-19 15:01:46.558406+07	16	auto	\N	\N	\N	{}	\N	\N
12155	1146	43	f	\N	\N	2026-09-19 15:01:46.558406+07	17	auto	\N	\N	\N	{}	\N	\N
12156	1146	48	f	\N	\N	2026-09-19 15:01:46.558406+07	14	auto	\N	\N	\N	{}	\N	\N
12157	1146	52	f	\N	\N	2026-09-19 15:01:46.558406+07	15	auto	\N	\N	\N	{}	\N	\N
12158	1146	82	f	\N	\N	2026-09-19 15:01:46.558406+07	8	auto	\N	\N	\N	{}	\N	\N
12159	1146	58	f	\N	\N	2026-09-19 15:01:46.558406+07	9	auto	\N	\N	\N	{}	\N	\N
12160	1146	71	f	\N	\N	2026-09-19 15:01:46.558406+07	10	auto	\N	\N	\N	{}	\N	\N
12161	1146	45	f	\N	\N	2026-09-19 15:01:46.558406+07	11	auto	\N	\N	\N	{}	\N	\N
12162	1147	136	f	\N	\N	2026-09-19 15:01:46.658306+07	6	auto	\N	\N	\N	{}	\N	\N
12163	1147	8	f	\N	\N	2026-09-19 15:01:46.658306+07	7	auto	\N	\N	\N	{}	\N	\N
12164	1147	73	f	\N	\N	2026-09-19 15:01:46.658306+07	13	auto	\N	\N	\N	{}	\N	\N
12165	1147	70	f	\N	\N	2026-09-19 15:01:46.658306+07	12	auto	\N	\N	\N	{}	\N	\N
12166	1147	47	f	\N	\N	2026-09-19 15:01:46.658306+07	16	auto	\N	\N	\N	{}	\N	\N
12167	1147	51	f	\N	\N	2026-09-19 15:01:46.658306+07	17	auto	\N	\N	\N	{}	\N	\N
12168	1147	60	f	\N	\N	2026-09-19 15:01:46.658306+07	14	auto	\N	\N	\N	{}	\N	\N
12169	1147	64	f	\N	\N	2026-09-19 15:01:46.658306+07	15	auto	\N	\N	\N	{}	\N	\N
12170	1147	75	f	\N	\N	2026-09-19 15:01:46.658306+07	8	auto	\N	\N	\N	{}	\N	\N
12171	1147	53	f	\N	\N	2026-09-19 15:01:46.658306+07	9	auto	\N	\N	\N	{}	\N	\N
12172	1147	72	f	\N	\N	2026-09-19 15:01:46.658306+07	10	auto	\N	\N	\N	{}	\N	\N
12173	1147	66	f	\N	\N	2026-09-19 15:01:46.658306+07	11	auto	\N	\N	\N	{}	\N	\N
12174	1148	137	f	\N	\N	2026-09-19 15:01:46.842332+07	6	auto	\N	\N	\N	{}	\N	\N
12175	1148	9	f	\N	\N	2026-09-19 15:01:46.842332+07	7	auto	\N	\N	\N	{}	\N	\N
12176	1148	77	f	\N	\N	2026-09-19 15:01:46.842332+07	13	auto	\N	\N	\N	{}	\N	\N
12177	1148	88	f	\N	\N	2026-09-19 15:01:46.842332+07	12	auto	\N	\N	\N	{}	\N	\N
12178	1148	55	f	\N	\N	2026-09-19 15:01:46.842332+07	16	auto	\N	\N	\N	{}	\N	\N
12179	1148	57	f	\N	\N	2026-09-19 15:01:46.842332+07	17	auto	\N	\N	\N	{}	\N	\N
12180	1148	37	f	\N	\N	2026-09-19 15:01:46.842332+07	14	auto	\N	\N	\N	{}	\N	\N
12181	1148	42	f	\N	\N	2026-09-19 15:01:46.842332+07	15	auto	\N	\N	\N	{}	\N	\N
12182	1148	84	f	\N	\N	2026-09-19 15:01:46.842332+07	8	auto	\N	\N	\N	{}	\N	\N
12183	1148	90	f	\N	\N	2026-09-19 15:01:46.842332+07	9	auto	\N	\N	\N	{}	\N	\N
12184	1148	83	f	\N	\N	2026-09-19 15:01:46.842332+07	10	auto	\N	\N	\N	{}	\N	\N
12185	1148	61	f	\N	\N	2026-09-19 15:01:46.842332+07	11	auto	\N	\N	\N	{}	\N	\N
12186	1149	138	f	\N	\N	2026-09-19 15:01:46.850464+07	6	auto	\N	\N	\N	{}	\N	\N
12078	1140	118	f	\N	\N	2026-09-19 15:01:45.792367+07	6	auto	\N	\N	\N	{}	\N	\N
12079	1140	119	f	\N	\N	2026-09-19 15:01:45.792367+07	7	auto	\N	\N	\N	{}	\N	\N
12080	1140	71	f	\N	\N	2026-09-19 15:01:45.792367+07	13	auto	\N	\N	\N	{}	\N	\N
12081	1140	78	f	\N	\N	2026-09-19 15:01:45.792367+07	12	auto	\N	\N	\N	{}	\N	\N
12082	1140	41	f	\N	\N	2026-09-19 15:01:45.792367+07	16	auto	\N	\N	\N	{}	\N	\N
12083	1140	43	f	\N	\N	2026-09-19 15:01:45.792367+07	17	auto	\N	\N	\N	{}	\N	\N
12084	1140	25	f	\N	\N	2026-09-19 15:01:45.792367+07	14	auto	\N	\N	\N	{}	\N	\N
12085	1140	37	f	\N	\N	2026-09-19 15:01:45.792367+07	15	auto	\N	\N	\N	{}	\N	\N
12086	1140	5	f	\N	\N	2026-09-19 15:01:45.792367+07	8	auto	\N	\N	\N	{}	\N	\N
12087	1140	42	f	\N	\N	2026-09-19 15:01:45.792367+07	9	auto	\N	\N	\N	{}	\N	\N
12088	1140	73	f	\N	\N	2026-09-19 15:01:45.792367+07	10	auto	\N	\N	\N	{}	\N	\N
12089	1140	45	f	\N	\N	2026-09-19 15:01:45.792367+07	11	auto	\N	\N	\N	{}	\N	\N
12090	1141	121	f	\N	\N	2026-09-19 15:01:45.973159+07	6	auto	\N	\N	\N	{}	\N	\N
12091	1141	123	f	\N	\N	2026-09-19 15:01:45.973159+07	7	auto	\N	\N	\N	{}	\N	\N
12092	1141	75	f	\N	\N	2026-09-19 15:01:45.973159+07	13	auto	\N	\N	\N	{}	\N	\N
12093	1141	17	f	\N	\N	2026-09-19 15:01:45.973159+07	12	auto	\N	\N	\N	{}	\N	\N
12094	1141	47	f	\N	\N	2026-09-19 15:01:45.973159+07	16	auto	\N	\N	\N	{}	\N	\N
12095	1141	51	f	\N	\N	2026-09-19 15:01:45.973159+07	17	auto	\N	\N	\N	{}	\N	\N
12096	1141	46	f	\N	\N	2026-09-19 15:01:45.973159+07	14	auto	\N	\N	\N	{}	\N	\N
12097	1141	54	f	\N	\N	2026-09-19 15:01:45.973159+07	15	auto	\N	\N	\N	{}	\N	\N
12098	1141	77	f	\N	\N	2026-09-19 15:01:45.973159+07	8	auto	\N	\N	\N	{}	\N	\N
12099	1141	53	f	\N	\N	2026-09-19 15:01:45.973159+07	9	auto	\N	\N	\N	{}	\N	\N
12100	1141	76	f	\N	\N	2026-09-19 15:01:45.973159+07	10	auto	\N	\N	\N	{}	\N	\N
12101	1141	48	f	\N	\N	2026-09-19 15:01:45.973159+07	11	auto	\N	\N	\N	{}	\N	\N
12102	1142	124	f	\N	\N	2026-09-19 15:01:45.982126+07	6	auto	\N	\N	\N	{}	\N	\N
12103	1142	125	f	\N	\N	2026-09-19 15:01:45.982126+07	7	auto	\N	\N	\N	{}	\N	\N
12104	1142	83	f	\N	\N	2026-09-19 15:01:45.982126+07	13	auto	\N	\N	\N	{}	\N	\N
12105	1142	70	f	\N	\N	2026-09-19 15:01:45.982126+07	12	auto	\N	\N	\N	{}	\N	\N
12106	1142	55	f	\N	\N	2026-09-19 15:01:45.982126+07	16	auto	\N	\N	\N	{}	\N	\N
12107	1142	57	f	\N	\N	2026-09-19 15:01:45.982126+07	17	auto	\N	\N	\N	{}	\N	\N
12108	1142	52	f	\N	\N	2026-09-19 15:01:45.982126+07	14	auto	\N	\N	\N	{}	\N	\N
12109	1142	58	f	\N	\N	2026-09-19 15:01:45.982126+07	15	auto	\N	\N	\N	{}	\N	\N
12110	1142	72	f	\N	\N	2026-09-19 15:01:45.982126+07	8	auto	\N	\N	\N	{}	\N	\N
12111	1142	82	f	\N	\N	2026-09-19 15:01:45.982126+07	9	auto	\N	\N	\N	{}	\N	\N
12112	1142	85	f	\N	\N	2026-09-19 15:01:45.982126+07	10	auto	\N	\N	\N	{}	\N	\N
12113	1142	61	f	\N	\N	2026-09-19 15:01:45.982126+07	11	auto	\N	\N	\N	{}	\N	\N
12114	1143	126	f	\N	\N	2026-09-19 15:01:45.983314+07	6	auto	\N	\N	\N	{}	\N	\N
12115	1143	127	f	\N	\N	2026-09-19 15:01:45.983314+07	7	auto	\N	\N	\N	{}	\N	\N
12116	1143	87	f	\N	\N	2026-09-19 15:01:45.983314+07	13	auto	\N	\N	\N	{}	\N	\N
12117	1143	88	f	\N	\N	2026-09-19 15:01:45.983314+07	12	auto	\N	\N	\N	{}	\N	\N
12118	1143	63	f	\N	\N	2026-09-19 15:01:45.983314+07	16	auto	\N	\N	\N	{}	\N	\N
12119	1143	65	f	\N	\N	2026-09-19 15:01:45.983314+07	17	auto	\N	\N	\N	{}	\N	\N
12120	1143	60	f	\N	\N	2026-09-19 15:01:45.983314+07	14	auto	\N	\N	\N	{}	\N	\N
12121	1143	64	f	\N	\N	2026-09-19 15:01:45.983314+07	15	auto	\N	\N	\N	{}	\N	\N
12122	1143	89	f	\N	\N	2026-09-19 15:01:45.983314+07	8	auto	\N	\N	\N	{}	\N	\N
12123	1143	67	f	\N	\N	2026-09-19 15:01:45.983314+07	9	auto	\N	\N	\N	{}	\N	\N
12124	1143	84	f	\N	\N	2026-09-19 15:01:45.983314+07	10	auto	\N	\N	\N	{}	\N	\N
12125	1143	66	f	\N	\N	2026-09-19 15:01:45.983314+07	11	auto	\N	\N	\N	{}	\N	\N
12210	1151	142	f	\N	\N	2026-09-19 15:01:47.226212+07	6	auto	\N	\N	\N	{}	\N	\N
12211	1151	99	f	\N	\N	2026-09-19 15:01:47.226212+07	7	auto	\N	\N	\N	{}	\N	\N
12212	1151	91	f	\N	\N	2026-09-19 15:01:47.226212+07	13	auto	\N	\N	\N	{}	\N	\N
12213	1151	17	f	\N	\N	2026-09-19 15:01:47.226212+07	12	auto	\N	\N	\N	{}	\N	\N
12214	1151	12	f	\N	\N	2026-09-19 15:01:47.226212+07	16	auto	\N	\N	\N	{}	\N	\N
12215	1151	24	f	\N	\N	2026-09-19 15:01:47.226212+07	17	auto	\N	\N	\N	{}	\N	\N
12216	1151	58	f	\N	\N	2026-09-19 15:01:47.226212+07	14	auto	\N	\N	\N	{}	\N	\N
12217	1151	60	f	\N	\N	2026-09-19 15:01:47.226212+07	15	auto	\N	\N	\N	{}	\N	\N
12218	1151	4	f	\N	\N	2026-09-19 15:01:47.226212+07	8	auto	\N	\N	\N	{}	\N	\N
12219	1151	16	f	\N	\N	2026-09-19 15:01:47.226212+07	9	auto	\N	\N	\N	{}	\N	\N
12220	1151	70	f	\N	\N	2026-09-19 15:01:47.226212+07	10	auto	\N	\N	\N	{}	\N	\N
12221	1151	64	f	\N	\N	2026-09-19 15:01:47.226212+07	11	auto	\N	\N	\N	{}	\N	\N
12234	1153	144	f	\N	\N	2026-09-19 15:01:47.444045+07	6	auto	\N	\N	\N	{}	\N	\N
12235	1153	103	f	\N	\N	2026-09-19 15:01:47.444045+07	7	auto	\N	\N	\N	{}	\N	\N
12236	1153	73	f	\N	\N	2026-09-19 15:01:47.444045+07	13	auto	\N	\N	\N	{}	\N	\N
12237	1153	90	f	\N	\N	2026-09-19 15:01:47.444045+07	12	auto	\N	\N	\N	{}	\N	\N
12238	1153	47	f	\N	\N	2026-09-19 15:01:47.444045+07	16	auto	\N	\N	\N	{}	\N	\N
12239	1153	51	f	\N	\N	2026-09-19 15:01:47.444045+07	17	auto	\N	\N	\N	{}	\N	\N
12240	1153	42	f	\N	\N	2026-09-19 15:01:47.444045+07	14	auto	\N	\N	\N	{}	\N	\N
12241	1153	54	f	\N	\N	2026-09-19 15:01:47.444045+07	15	auto	\N	\N	\N	{}	\N	\N
12242	1153	75	f	\N	\N	2026-09-19 15:01:47.444045+07	8	auto	\N	\N	\N	{}	\N	\N
12243	1153	53	f	\N	\N	2026-09-19 15:01:47.444045+07	9	auto	\N	\N	\N	{}	\N	\N
12244	1153	29	f	\N	\N	2026-09-19 15:01:47.444045+07	10	auto	\N	\N	\N	{}	\N	\N
12245	1153	78	f	\N	\N	2026-09-19 15:01:47.444045+07	11	auto	\N	\N	\N	{}	\N	\N
12318	1160	137	f	\N	\N	2026-09-19 15:01:48.60933+07	6	auto	\N	\N	\N	{}	\N	\N
12319	1160	109	f	\N	\N	2026-09-19 15:01:48.60933+07	7	auto	\N	\N	\N	{}	\N	\N
12320	1160	83	f	\N	\N	2026-09-19 15:01:48.60933+07	13	auto	\N	\N	\N	{}	\N	\N
12321	1160	5	f	\N	\N	2026-09-19 15:01:48.60933+07	12	auto	\N	\N	\N	{}	\N	\N
12322	1160	12	f	\N	\N	2026-09-19 15:01:48.60933+07	16	auto	\N	\N	\N	{}	\N	\N
12323	1160	49	f	\N	\N	2026-09-19 15:01:48.60933+07	17	auto	\N	\N	\N	{}	\N	\N
12324	1160	60	f	\N	\N	2026-09-19 15:01:48.60933+07	14	auto	\N	\N	\N	{}	\N	\N
12325	1160	48	f	\N	\N	2026-09-19 15:01:48.60933+07	15	auto	\N	\N	\N	{}	\N	\N
12326	1160	84	f	\N	\N	2026-09-19 15:01:48.60933+07	8	auto	\N	\N	\N	{}	\N	\N
12327	1160	17	f	\N	\N	2026-09-19 15:01:48.60933+07	9	auto	\N	\N	\N	{}	\N	\N
12328	1160	85	f	\N	\N	2026-09-19 15:01:48.60933+07	10	auto	\N	\N	\N	{}	\N	\N
12329	1160	4	f	\N	\N	2026-09-19 15:01:48.60933+07	11	auto	\N	\N	\N	{}	\N	\N
12330	1161	22	f	\N	\N	2026-09-19 15:01:48.755028+07	6	auto	\N	\N	\N	{}	\N	\N
12331	1161	101	f	\N	\N	2026-09-19 15:01:48.755028+07	7	auto	\N	\N	\N	{}	\N	\N
12332	1161	16	f	\N	\N	2026-09-19 15:01:48.755028+07	13	auto	\N	\N	\N	{}	\N	\N
12333	1161	70	f	\N	\N	2026-09-19 15:01:48.755028+07	12	auto	\N	\N	\N	{}	\N	\N
12334	1161	69	f	\N	\N	2026-09-19 15:01:48.755028+07	16	auto	\N	\N	\N	{}	\N	\N
12335	1161	24	f	\N	\N	2026-09-19 15:01:48.755028+07	17	auto	\N	\N	\N	{}	\N	\N
12336	1161	58	f	\N	\N	2026-09-19 15:01:48.755028+07	14	auto	\N	\N	\N	{}	\N	\N
12337	1161	42	f	\N	\N	2026-09-19 15:01:48.755028+07	15	auto	\N	\N	\N	{}	\N	\N
12338	1161	87	f	\N	\N	2026-09-19 15:01:48.755028+07	8	auto	\N	\N	\N	{}	\N	\N
12339	1161	41	f	\N	\N	2026-09-19 15:01:48.755028+07	9	auto	\N	\N	\N	{}	\N	\N
12340	1161	78	f	\N	\N	2026-09-19 15:01:48.755028+07	10	auto	\N	\N	\N	{}	\N	\N
12341	1161	66	f	\N	\N	2026-09-19 15:01:48.755028+07	11	auto	\N	\N	\N	{}	\N	\N
12342	1162	138	f	\N	\N	2026-09-19 15:01:48.899268+07	6	auto	\N	\N	\N	{}	\N	\N
12187	1149	94	f	\N	\N	2026-09-19 15:01:46.850464+07	7	auto	\N	\N	\N	{}	\N	\N
12188	1149	85	f	\N	\N	2026-09-19 15:01:46.850464+07	13	auto	\N	\N	\N	{}	\N	\N
12189	1149	29	f	\N	\N	2026-09-19 15:01:46.850464+07	12	auto	\N	\N	\N	{}	\N	\N
12190	1149	63	f	\N	\N	2026-09-19 15:01:46.850464+07	16	auto	\N	\N	\N	{}	\N	\N
12191	1149	65	f	\N	\N	2026-09-19 15:01:46.850464+07	17	auto	\N	\N	\N	{}	\N	\N
12192	1149	54	f	\N	\N	2026-09-19 15:01:46.850464+07	14	auto	\N	\N	\N	{}	\N	\N
12193	1149	46	f	\N	\N	2026-09-19 15:01:46.850464+07	15	auto	\N	\N	\N	{}	\N	\N
12194	1149	87	f	\N	\N	2026-09-19 15:01:46.850464+07	8	auto	\N	\N	\N	{}	\N	\N
12195	1149	67	f	\N	\N	2026-09-19 15:01:46.850464+07	9	auto	\N	\N	\N	{}	\N	\N
12196	1149	78	f	\N	\N	2026-09-19 15:01:46.850464+07	10	auto	\N	\N	\N	{}	\N	\N
12197	1149	76	f	\N	\N	2026-09-19 15:01:46.850464+07	11	auto	\N	\N	\N	{}	\N	\N
12198	1150	139	f	\N	\N	2026-09-19 15:01:46.851777+07	6	auto	\N	\N	\N	{}	\N	\N
12199	1150	97	f	\N	\N	2026-09-19 15:01:46.851777+07	7	auto	\N	\N	\N	{}	\N	\N
12200	1150	89	f	\N	\N	2026-09-19 15:01:46.851777+07	13	auto	\N	\N	\N	{}	\N	\N
12201	1150	5	f	\N	\N	2026-09-19 15:01:46.851777+07	12	auto	\N	\N	\N	{}	\N	\N
12202	1150	36	f	\N	\N	2026-09-19 15:01:46.851777+07	16	auto	\N	\N	\N	{}	\N	\N
12203	1150	49	f	\N	\N	2026-09-19 15:01:46.851777+07	17	auto	\N	\N	\N	{}	\N	\N
12204	1150	25	f	\N	\N	2026-09-19 15:01:46.851777+07	14	auto	\N	\N	\N	{}	\N	\N
12205	1150	48	f	\N	\N	2026-09-19 15:01:46.851777+07	15	auto	\N	\N	\N	{}	\N	\N
12206	1150	82	f	\N	\N	2026-09-19 15:01:46.851777+07	8	auto	\N	\N	\N	{}	\N	\N
12207	1150	52	f	\N	\N	2026-09-19 15:01:46.851777+07	9	auto	\N	\N	\N	{}	\N	\N
12208	1150	81	f	\N	\N	2026-09-19 15:01:46.851777+07	10	auto	\N	\N	\N	{}	\N	\N
12209	1150	69	f	\N	\N	2026-09-19 15:01:46.851777+07	11	auto	\N	\N	\N	{}	\N	\N
12258	1155	147	f	\N	\N	2026-09-19 15:01:47.742544+07	6	auto	\N	\N	\N	{}	\N	\N
12259	1155	106	f	\N	\N	2026-09-19 15:01:47.742544+07	7	auto	\N	\N	\N	{}	\N	\N
12260	1155	77	f	\N	\N	2026-09-19 15:01:47.742544+07	13	auto	\N	\N	\N	{}	\N	\N
12261	1155	70	f	\N	\N	2026-09-19 15:01:47.742544+07	12	auto	\N	\N	\N	{}	\N	\N
12262	1155	63	f	\N	\N	2026-09-19 15:01:47.742544+07	16	auto	\N	\N	\N	{}	\N	\N
12263	1155	65	f	\N	\N	2026-09-19 15:01:47.742544+07	17	auto	\N	\N	\N	{}	\N	\N
12264	1155	52	f	\N	\N	2026-09-19 15:01:47.742544+07	14	auto	\N	\N	\N	{}	\N	\N
12265	1155	25	f	\N	\N	2026-09-19 15:01:47.742544+07	15	auto	\N	\N	\N	{}	\N	\N
12266	1155	85	f	\N	\N	2026-09-19 15:01:47.742544+07	8	auto	\N	\N	\N	{}	\N	\N
12267	1155	67	f	\N	\N	2026-09-19 15:01:47.742544+07	9	auto	\N	\N	\N	{}	\N	\N
12268	1155	17	f	\N	\N	2026-09-19 15:01:47.742544+07	10	auto	\N	\N	\N	{}	\N	\N
12269	1155	60	f	\N	\N	2026-09-19 15:01:47.742544+07	11	auto	\N	\N	\N	{}	\N	\N
12270	1156	148	f	\N	\N	2026-09-19 15:01:47.750718+07	6	auto	\N	\N	\N	{}	\N	\N
12271	1156	93	f	\N	\N	2026-09-19 15:01:47.750718+07	7	auto	\N	\N	\N	{}	\N	\N
12272	1156	87	f	\N	\N	2026-09-19 15:01:47.750718+07	13	auto	\N	\N	\N	{}	\N	\N
12273	1156	72	f	\N	\N	2026-09-19 15:01:47.750718+07	12	auto	\N	\N	\N	{}	\N	\N
12274	1156	36	f	\N	\N	2026-09-19 15:01:47.750718+07	16	auto	\N	\N	\N	{}	\N	\N
12275	1156	49	f	\N	\N	2026-09-19 15:01:47.750718+07	17	auto	\N	\N	\N	{}	\N	\N
12276	1156	64	f	\N	\N	2026-09-19 15:01:47.750718+07	14	auto	\N	\N	\N	{}	\N	\N
12277	1156	58	f	\N	\N	2026-09-19 15:01:47.750718+07	15	auto	\N	\N	\N	{}	\N	\N
12278	1156	84	f	\N	\N	2026-09-19 15:01:47.750718+07	8	auto	\N	\N	\N	{}	\N	\N
12279	1156	66	f	\N	\N	2026-09-19 15:01:47.750718+07	9	auto	\N	\N	\N	{}	\N	\N
12280	1156	81	f	\N	\N	2026-09-19 15:01:47.750718+07	10	auto	\N	\N	\N	{}	\N	\N
12281	1156	69	f	\N	\N	2026-09-19 15:01:47.750718+07	11	auto	\N	\N	\N	{}	\N	\N
12282	1157	149	f	\N	\N	2026-09-19 15:01:47.751978+07	6	auto	\N	\N	\N	{}	\N	\N
12283	1157	96	f	\N	\N	2026-09-19 15:01:47.751978+07	7	auto	\N	\N	\N	{}	\N	\N
12284	1157	89	f	\N	\N	2026-09-19 15:01:47.751978+07	13	auto	\N	\N	\N	{}	\N	\N
12285	1157	88	f	\N	\N	2026-09-19 15:01:47.751978+07	12	auto	\N	\N	\N	{}	\N	\N
12286	1157	12	f	\N	\N	2026-09-19 15:01:47.751978+07	16	auto	\N	\N	\N	{}	\N	\N
12287	1157	24	f	\N	\N	2026-09-19 15:01:47.751978+07	17	auto	\N	\N	\N	{}	\N	\N
12288	1157	37	f	\N	\N	2026-09-19 15:01:47.751978+07	14	auto	\N	\N	\N	{}	\N	\N
12289	1157	42	f	\N	\N	2026-09-19 15:01:47.751978+07	15	auto	\N	\N	\N	{}	\N	\N
12290	1157	91	f	\N	\N	2026-09-19 15:01:47.751978+07	8	auto	\N	\N	\N	{}	\N	\N
12291	1157	4	f	\N	\N	2026-09-19 15:01:47.751978+07	9	auto	\N	\N	\N	{}	\N	\N
12292	1157	90	f	\N	\N	2026-09-19 15:01:47.751978+07	10	auto	\N	\N	\N	{}	\N	\N
12293	1157	82	f	\N	\N	2026-09-19 15:01:47.751978+07	11	auto	\N	\N	\N	{}	\N	\N
12558	1180	135	f	\N	\N	2026-09-19 15:01:52.084393+07	6	auto	\N	\N	\N	{}	\N	\N
12559	1180	125	f	\N	\N	2026-09-19 15:01:52.084393+07	7	auto	\N	\N	\N	{}	\N	\N
12560	1180	87	f	\N	\N	2026-09-19 15:01:52.084393+07	13	auto	\N	\N	\N	{}	\N	\N
12561	1180	82	f	\N	\N	2026-09-19 15:01:52.084393+07	12	auto	\N	\N	\N	{}	\N	\N
12562	1180	41	f	\N	\N	2026-09-19 15:01:52.084393+07	16	auto	\N	\N	\N	{}	\N	\N
12563	1180	43	f	\N	\N	2026-09-19 15:01:52.084393+07	17	auto	\N	\N	\N	{}	\N	\N
12564	1180	37	f	\N	\N	2026-09-19 15:01:52.084393+07	14	auto	\N	\N	\N	{}	\N	\N
12565	1180	42	f	\N	\N	2026-09-19 15:01:52.084393+07	15	auto	\N	\N	\N	{}	\N	\N
12566	1180	72	f	\N	\N	2026-09-19 15:01:52.084393+07	8	auto	\N	\N	\N	{}	\N	\N
12567	1180	90	f	\N	\N	2026-09-19 15:01:52.084393+07	9	auto	\N	\N	\N	{}	\N	\N
12568	1180	89	f	\N	\N	2026-09-19 15:01:52.084393+07	10	auto	\N	\N	\N	{}	\N	\N
12569	1180	28	f	\N	\N	2026-09-19 15:01:52.084393+07	11	auto	\N	\N	\N	{}	\N	\N
12570	1181	147	f	\N	\N	2026-09-19 15:01:52.092294+07	6	auto	\N	\N	\N	{}	\N	\N
12571	1181	126	f	\N	\N	2026-09-19 15:01:52.092294+07	7	auto	\N	\N	\N	{}	\N	\N
12572	1181	91	f	\N	\N	2026-09-19 15:01:52.092294+07	13	auto	\N	\N	\N	{}	\N	\N
12573	1181	76	f	\N	\N	2026-09-19 15:01:52.092294+07	12	auto	\N	\N	\N	{}	\N	\N
12574	1181	45	f	\N	\N	2026-09-19 15:01:52.092294+07	16	auto	\N	\N	\N	{}	\N	\N
12575	1181	47	f	\N	\N	2026-09-19 15:01:52.092294+07	17	auto	\N	\N	\N	{}	\N	\N
12576	1181	25	f	\N	\N	2026-09-19 15:01:52.092294+07	14	auto	\N	\N	\N	{}	\N	\N
12577	1181	64	f	\N	\N	2026-09-19 15:01:52.092294+07	15	auto	\N	\N	\N	{}	\N	\N
12578	1181	75	f	\N	\N	2026-09-19 15:01:52.092294+07	8	auto	\N	\N	\N	{}	\N	\N
12579	1181	51	f	\N	\N	2026-09-19 15:01:52.092294+07	9	auto	\N	\N	\N	{}	\N	\N
12580	1181	5	f	\N	\N	2026-09-19 15:01:52.092294+07	10	auto	\N	\N	\N	{}	\N	\N
12581	1181	29	f	\N	\N	2026-09-19 15:01:52.092294+07	11	auto	\N	\N	\N	{}	\N	\N
12222	1152	143	f	\N	\N	2026-09-19 15:01:47.335703+07	6	auto	\N	\N	\N	{}	\N	\N
12223	1152	101	f	\N	\N	2026-09-19 15:01:47.335703+07	7	auto	\N	\N	\N	{}	\N	\N
12224	1152	28	f	\N	\N	2026-09-19 15:01:47.335703+07	13	auto	\N	\N	\N	{}	\N	\N
12225	1152	72	f	\N	\N	2026-09-19 15:01:47.335703+07	12	auto	\N	\N	\N	{}	\N	\N
12226	1152	41	f	\N	\N	2026-09-19 15:01:47.335703+07	16	auto	\N	\N	\N	{}	\N	\N
12227	1152	43	f	\N	\N	2026-09-19 15:01:47.335703+07	17	auto	\N	\N	\N	{}	\N	\N
12228	1152	66	f	\N	\N	2026-09-19 15:01:47.335703+07	14	auto	\N	\N	\N	{}	\N	\N
12229	1152	37	f	\N	\N	2026-09-19 15:01:47.335703+07	15	auto	\N	\N	\N	{}	\N	\N
12230	1152	84	f	\N	\N	2026-09-19 15:01:47.335703+07	8	auto	\N	\N	\N	{}	\N	\N
12231	1152	88	f	\N	\N	2026-09-19 15:01:47.335703+07	9	auto	\N	\N	\N	{}	\N	\N
12232	1152	71	f	\N	\N	2026-09-19 15:01:47.335703+07	10	auto	\N	\N	\N	{}	\N	\N
12233	1152	45	f	\N	\N	2026-09-19 15:01:47.335703+07	11	auto	\N	\N	\N	{}	\N	\N
12246	1154	145	f	\N	\N	2026-09-19 15:01:47.554991+07	6	auto	\N	\N	\N	{}	\N	\N
12247	1154	105	f	\N	\N	2026-09-19 15:01:47.554991+07	7	auto	\N	\N	\N	{}	\N	\N
12248	1154	32	f	\N	\N	2026-09-19 15:01:47.554991+07	13	auto	\N	\N	\N	{}	\N	\N
12249	1154	76	f	\N	\N	2026-09-19 15:01:47.554991+07	12	auto	\N	\N	\N	{}	\N	\N
12250	1154	55	f	\N	\N	2026-09-19 15:01:47.554991+07	16	auto	\N	\N	\N	{}	\N	\N
12251	1154	57	f	\N	\N	2026-09-19 15:01:47.554991+07	17	auto	\N	\N	\N	{}	\N	\N
12252	1154	46	f	\N	\N	2026-09-19 15:01:47.554991+07	14	auto	\N	\N	\N	{}	\N	\N
12253	1154	48	f	\N	\N	2026-09-19 15:01:47.554991+07	15	auto	\N	\N	\N	{}	\N	\N
12254	1154	82	f	\N	\N	2026-09-19 15:01:47.554991+07	8	auto	\N	\N	\N	{}	\N	\N
12255	1154	5	f	\N	\N	2026-09-19 15:01:47.554991+07	9	auto	\N	\N	\N	{}	\N	\N
12256	1154	83	f	\N	\N	2026-09-19 15:01:47.554991+07	10	auto	\N	\N	\N	{}	\N	\N
12257	1154	61	f	\N	\N	2026-09-19 15:01:47.554991+07	11	auto	\N	\N	\N	{}	\N	\N
12294	1158	149	f	\N	\N	2026-09-19 15:01:48.318036+07	6	auto	\N	\N	\N	{}	\N	\N
12295	1158	107	f	\N	\N	2026-09-19 15:01:48.318036+07	7	auto	\N	\N	\N	{}	\N	\N
12296	1158	75	f	\N	\N	2026-09-19 15:01:48.318036+07	13	auto	\N	\N	\N	{}	\N	\N
12297	1158	82	f	\N	\N	2026-09-19 15:01:48.318036+07	12	auto	\N	\N	\N	{}	\N	\N
12298	1158	57	f	\N	\N	2026-09-19 15:01:48.318036+07	16	auto	\N	\N	\N	{}	\N	\N
12299	1158	61	f	\N	\N	2026-09-19 15:01:48.318036+07	17	auto	\N	\N	\N	{}	\N	\N
12300	1158	54	f	\N	\N	2026-09-19 15:01:48.318036+07	14	auto	\N	\N	\N	{}	\N	\N
12301	1158	52	f	\N	\N	2026-09-19 15:01:48.318036+07	15	auto	\N	\N	\N	{}	\N	\N
12302	1158	72	f	\N	\N	2026-09-19 15:01:48.318036+07	8	auto	\N	\N	\N	{}	\N	\N
12303	1158	64	f	\N	\N	2026-09-19 15:01:48.318036+07	9	auto	\N	\N	\N	{}	\N	\N
12304	1158	73	f	\N	\N	2026-09-19 15:01:48.318036+07	10	auto	\N	\N	\N	{}	\N	\N
12305	1158	63	f	\N	\N	2026-09-19 15:01:48.318036+07	11	auto	\N	\N	\N	{}	\N	\N
12354	1163	35	f	\N	\N	2026-09-19 15:01:49.135971+07	6	auto	\N	\N	\N	{}	\N	\N
12355	1163	103	f	\N	\N	2026-09-19 15:01:49.135971+07	7	auto	\N	\N	\N	{}	\N	\N
12356	1163	91	f	\N	\N	2026-09-19 15:01:49.135971+07	13	auto	\N	\N	\N	{}	\N	\N
12357	1163	82	f	\N	\N	2026-09-19 15:01:49.135971+07	12	auto	\N	\N	\N	{}	\N	\N
12358	1163	51	f	\N	\N	2026-09-19 15:01:49.135971+07	16	auto	\N	\N	\N	{}	\N	\N
12359	1163	53	f	\N	\N	2026-09-19 15:01:49.135971+07	17	auto	\N	\N	\N	{}	\N	\N
12360	1163	64	f	\N	\N	2026-09-19 15:01:49.135971+07	14	auto	\N	\N	\N	{}	\N	\N
12361	1163	25	f	\N	\N	2026-09-19 15:01:49.135971+07	15	auto	\N	\N	\N	{}	\N	\N
12362	1163	71	f	\N	\N	2026-09-19 15:01:49.135971+07	8	auto	\N	\N	\N	{}	\N	\N
12363	1163	55	f	\N	\N	2026-09-19 15:01:49.135971+07	9	auto	\N	\N	\N	{}	\N	\N
12364	1163	76	f	\N	\N	2026-09-19 15:01:49.135971+07	10	auto	\N	\N	\N	{}	\N	\N
12365	1163	90	f	\N	\N	2026-09-19 15:01:49.135971+07	11	auto	\N	\N	\N	{}	\N	\N
12366	1164	34	f	\N	\N	2026-09-19 15:01:49.144097+07	6	auto	\N	\N	\N	{}	\N	\N
12367	1164	112	f	\N	\N	2026-09-19 15:01:49.144097+07	7	auto	\N	\N	\N	{}	\N	\N
12368	1164	73	f	\N	\N	2026-09-19 15:01:49.144097+07	13	auto	\N	\N	\N	{}	\N	\N
12369	1164	29	f	\N	\N	2026-09-19 15:01:49.144097+07	12	auto	\N	\N	\N	{}	\N	\N
12370	1164	57	f	\N	\N	2026-09-19 15:01:49.144097+07	16	auto	\N	\N	\N	{}	\N	\N
12371	1164	61	f	\N	\N	2026-09-19 15:01:49.144097+07	17	auto	\N	\N	\N	{}	\N	\N
12372	1164	46	f	\N	\N	2026-09-19 15:01:49.144097+07	14	auto	\N	\N	\N	{}	\N	\N
12373	1164	60	f	\N	\N	2026-09-19 15:01:49.144097+07	15	auto	\N	\N	\N	{}	\N	\N
12374	1164	84	f	\N	\N	2026-09-19 15:01:49.144097+07	8	auto	\N	\N	\N	{}	\N	\N
12375	1164	17	f	\N	\N	2026-09-19 15:01:49.144097+07	9	auto	\N	\N	\N	{}	\N	\N
12376	1164	32	f	\N	\N	2026-09-19 15:01:49.144097+07	10	auto	\N	\N	\N	{}	\N	\N
12377	1164	63	f	\N	\N	2026-09-19 15:01:49.144097+07	11	auto	\N	\N	\N	{}	\N	\N
12378	1165	139	f	\N	\N	2026-09-19 15:01:49.145462+07	6	auto	\N	\N	\N	{}	\N	\N
12379	1165	105	f	\N	\N	2026-09-19 15:01:49.145462+07	7	auto	\N	\N	\N	{}	\N	\N
12380	1165	75	f	\N	\N	2026-09-19 15:01:49.145462+07	13	auto	\N	\N	\N	{}	\N	\N
12381	1165	5	f	\N	\N	2026-09-19 15:01:49.145462+07	12	auto	\N	\N	\N	{}	\N	\N
12382	1165	36	f	\N	\N	2026-09-19 15:01:49.145462+07	16	auto	\N	\N	\N	{}	\N	\N
12383	1165	65	f	\N	\N	2026-09-19 15:01:49.145462+07	17	auto	\N	\N	\N	{}	\N	\N
12384	1165	48	f	\N	\N	2026-09-19 15:01:49.145462+07	14	auto	\N	\N	\N	{}	\N	\N
12385	1165	66	f	\N	\N	2026-09-19 15:01:49.145462+07	15	auto	\N	\N	\N	{}	\N	\N
12386	1165	77	f	\N	\N	2026-09-19 15:01:49.145462+07	8	auto	\N	\N	\N	{}	\N	\N
12387	1165	67	f	\N	\N	2026-09-19 15:01:49.145462+07	9	auto	\N	\N	\N	{}	\N	\N
12388	1165	70	f	\N	\N	2026-09-19 15:01:49.145462+07	10	auto	\N	\N	\N	{}	\N	\N
12389	1165	58	f	\N	\N	2026-09-19 15:01:49.145462+07	11	auto	\N	\N	\N	{}	\N	\N
12402	1167	93	f	\N	\N	2026-09-19 15:01:49.784885+07	6	auto	\N	\N	\N	{}	\N	\N
12403	1167	106	f	\N	\N	2026-09-19 15:01:49.784885+07	7	auto	\N	\N	\N	{}	\N	\N
12404	1167	4	f	\N	\N	2026-09-19 15:01:49.784885+07	13	auto	\N	\N	\N	{}	\N	\N
12405	1167	72	f	\N	\N	2026-09-19 15:01:49.784885+07	12	auto	\N	\N	\N	{}	\N	\N
12406	1167	69	f	\N	\N	2026-09-19 15:01:49.784885+07	16	auto	\N	\N	\N	{}	\N	\N
12407	1167	24	f	\N	\N	2026-09-19 15:01:49.784885+07	17	auto	\N	\N	\N	{}	\N	\N
12408	1167	37	f	\N	\N	2026-09-19 15:01:49.784885+07	14	auto	\N	\N	\N	{}	\N	\N
12409	1167	64	f	\N	\N	2026-09-19 15:01:49.784885+07	15	auto	\N	\N	\N	{}	\N	\N
12410	1167	16	f	\N	\N	2026-09-19 15:01:49.784885+07	8	auto	\N	\N	\N	{}	\N	\N
12411	1167	41	f	\N	\N	2026-09-19 15:01:49.784885+07	9	auto	\N	\N	\N	{}	\N	\N
12412	1167	76	f	\N	\N	2026-09-19 15:01:49.784885+07	10	auto	\N	\N	\N	{}	\N	\N
12413	1167	82	f	\N	\N	2026-09-19 15:01:49.784885+07	11	auto	\N	\N	\N	{}	\N	\N
12498	1175	144	f	\N	\N	2026-09-19 15:01:51.12694+07	6	auto	\N	\N	\N	{}	\N	\N
12499	1175	132	f	\N	\N	2026-09-19 15:01:51.12694+07	7	auto	\N	\N	\N	{}	\N	\N
12500	1175	32	f	\N	\N	2026-09-19 15:01:51.12694+07	13	auto	\N	\N	\N	{}	\N	\N
12501	1175	88	f	\N	\N	2026-09-19 15:01:51.12694+07	12	auto	\N	\N	\N	{}	\N	\N
12502	1175	47	f	\N	\N	2026-09-19 15:01:51.12694+07	16	auto	\N	\N	\N	{}	\N	\N
12503	1175	51	f	\N	\N	2026-09-19 15:01:51.12694+07	17	auto	\N	\N	\N	{}	\N	\N
12504	1175	58	f	\N	\N	2026-09-19 15:01:51.12694+07	14	auto	\N	\N	\N	{}	\N	\N
12505	1175	52	f	\N	\N	2026-09-19 15:01:51.12694+07	15	auto	\N	\N	\N	{}	\N	\N
12506	1175	91	f	\N	\N	2026-09-19 15:01:51.12694+07	8	auto	\N	\N	\N	{}	\N	\N
12507	1175	53	f	\N	\N	2026-09-19 15:01:51.12694+07	9	auto	\N	\N	\N	{}	\N	\N
12508	1175	82	f	\N	\N	2026-09-19 15:01:51.12694+07	10	auto	\N	\N	\N	{}	\N	\N
12509	1175	72	f	\N	\N	2026-09-19 15:01:51.12694+07	11	auto	\N	\N	\N	{}	\N	\N
12510	1176	133	f	\N	\N	2026-09-19 15:01:51.277248+07	6	auto	\N	\N	\N	{}	\N	\N
12343	1162	111	f	\N	\N	2026-09-19 15:01:48.899268+07	7	auto	\N	\N	\N	{}	\N	\N
12344	1162	28	f	\N	\N	2026-09-19 15:01:48.899268+07	13	auto	\N	\N	\N	{}	\N	\N
12345	1162	88	f	\N	\N	2026-09-19 15:01:48.899268+07	12	auto	\N	\N	\N	{}	\N	\N
12346	1162	43	f	\N	\N	2026-09-19 15:01:48.899268+07	16	auto	\N	\N	\N	{}	\N	\N
12347	1162	45	f	\N	\N	2026-09-19 15:01:48.899268+07	17	auto	\N	\N	\N	{}	\N	\N
12348	1162	37	f	\N	\N	2026-09-19 15:01:48.899268+07	14	auto	\N	\N	\N	{}	\N	\N
12349	1162	52	f	\N	\N	2026-09-19 15:01:48.899268+07	15	auto	\N	\N	\N	{}	\N	\N
12350	1162	72	f	\N	\N	2026-09-19 15:01:48.899268+07	8	auto	\N	\N	\N	{}	\N	\N
12351	1162	54	f	\N	\N	2026-09-19 15:01:48.899268+07	9	auto	\N	\N	\N	{}	\N	\N
12352	1162	89	f	\N	\N	2026-09-19 15:01:48.899268+07	10	auto	\N	\N	\N	{}	\N	\N
12353	1162	47	f	\N	\N	2026-09-19 15:01:48.899268+07	11	auto	\N	\N	\N	{}	\N	\N
12390	1166	142	f	\N	\N	2026-09-19 15:01:49.636088+07	6	auto	\N	\N	\N	{}	\N	\N
12391	1166	123	f	\N	\N	2026-09-19 15:01:49.636088+07	7	auto	\N	\N	\N	{}	\N	\N
12392	1166	83	f	\N	\N	2026-09-19 15:01:49.636088+07	13	auto	\N	\N	\N	{}	\N	\N
12393	1166	78	f	\N	\N	2026-09-19 15:01:49.636088+07	12	auto	\N	\N	\N	{}	\N	\N
12394	1166	12	f	\N	\N	2026-09-19 15:01:49.636088+07	16	auto	\N	\N	\N	{}	\N	\N
12395	1166	49	f	\N	\N	2026-09-19 15:01:49.636088+07	17	auto	\N	\N	\N	{}	\N	\N
12396	1166	42	f	\N	\N	2026-09-19 15:01:49.636088+07	14	auto	\N	\N	\N	{}	\N	\N
12397	1166	52	f	\N	\N	2026-09-19 15:01:49.636088+07	15	auto	\N	\N	\N	{}	\N	\N
12398	1166	88	f	\N	\N	2026-09-19 15:01:49.636088+07	8	auto	\N	\N	\N	{}	\N	\N
12399	1166	54	f	\N	\N	2026-09-19 15:01:49.636088+07	9	auto	\N	\N	\N	{}	\N	\N
12400	1166	81	f	\N	\N	2026-09-19 15:01:49.636088+07	10	auto	\N	\N	\N	{}	\N	\N
12401	1166	85	f	\N	\N	2026-09-19 15:01:49.636088+07	11	auto	\N	\N	\N	{}	\N	\N
12414	1168	143	f	\N	\N	2026-09-19 15:01:49.935663+07	6	auto	\N	\N	\N	{}	\N	\N
12415	1168	113	f	\N	\N	2026-09-19 15:01:49.935663+07	7	auto	\N	\N	\N	{}	\N	\N
12416	1168	87	f	\N	\N	2026-09-19 15:01:49.935663+07	13	auto	\N	\N	\N	{}	\N	\N
12417	1168	90	f	\N	\N	2026-09-19 15:01:49.935663+07	12	auto	\N	\N	\N	{}	\N	\N
12418	1168	43	f	\N	\N	2026-09-19 15:01:49.935663+07	16	auto	\N	\N	\N	{}	\N	\N
12419	1168	45	f	\N	\N	2026-09-19 15:01:49.935663+07	17	auto	\N	\N	\N	{}	\N	\N
12420	1168	25	f	\N	\N	2026-09-19 15:01:49.935663+07	14	auto	\N	\N	\N	{}	\N	\N
12421	1168	60	f	\N	\N	2026-09-19 15:01:49.935663+07	15	auto	\N	\N	\N	{}	\N	\N
12422	1168	84	f	\N	\N	2026-09-19 15:01:49.935663+07	8	auto	\N	\N	\N	{}	\N	\N
12423	1168	17	f	\N	\N	2026-09-19 15:01:49.935663+07	9	auto	\N	\N	\N	{}	\N	\N
12424	1168	89	f	\N	\N	2026-09-19 15:01:49.935663+07	10	auto	\N	\N	\N	{}	\N	\N
12425	1168	28	f	\N	\N	2026-09-19 15:01:49.935663+07	11	auto	\N	\N	\N	{}	\N	\N
12474	1173	117	f	\N	\N	2026-09-19 15:01:50.828397+07	6	auto	\N	\N	\N	{}	\N	\N
12475	1173	118	f	\N	\N	2026-09-19 15:01:50.828397+07	7	auto	\N	\N	\N	{}	\N	\N
12476	1173	4	f	\N	\N	2026-09-19 15:01:50.828397+07	13	auto	\N	\N	\N	{}	\N	\N
12477	1173	17	f	\N	\N	2026-09-19 15:01:50.828397+07	12	auto	\N	\N	\N	{}	\N	\N
12478	1173	69	f	\N	\N	2026-09-19 15:01:50.828397+07	16	auto	\N	\N	\N	{}	\N	\N
12479	1173	24	f	\N	\N	2026-09-19 15:01:50.828397+07	17	auto	\N	\N	\N	{}	\N	\N
12480	1173	60	f	\N	\N	2026-09-19 15:01:50.828397+07	14	auto	\N	\N	\N	{}	\N	\N
12481	1173	66	f	\N	\N	2026-09-19 15:01:50.828397+07	15	auto	\N	\N	\N	{}	\N	\N
12482	1173	16	f	\N	\N	2026-09-19 15:01:50.828397+07	8	auto	\N	\N	\N	{}	\N	\N
12483	1173	41	f	\N	\N	2026-09-19 15:01:50.828397+07	9	auto	\N	\N	\N	{}	\N	\N
12484	1173	5	f	\N	\N	2026-09-19 15:01:50.828397+07	10	auto	\N	\N	\N	{}	\N	\N
12485	1173	29	f	\N	\N	2026-09-19 15:01:50.828397+07	11	auto	\N	\N	\N	{}	\N	\N
12582	1182	99	f	\N	\N	2026-09-19 15:01:52.382595+07	6	auto	\N	\N	\N	{}	\N	\N
12583	1182	107	f	\N	\N	2026-09-19 15:01:52.382595+07	7	auto	\N	\N	\N	{}	\N	\N
12584	1182	71	f	\N	\N	2026-09-19 15:01:52.382595+07	13	auto	\N	\N	\N	{}	\N	\N
12585	1182	70	f	\N	\N	2026-09-19 15:01:52.382595+07	12	auto	\N	\N	\N	{}	\N	\N
12586	1182	53	f	\N	\N	2026-09-19 15:01:52.382595+07	16	auto	\N	\N	\N	{}	\N	\N
12587	1182	55	f	\N	\N	2026-09-19 15:01:52.382595+07	17	auto	\N	\N	\N	{}	\N	\N
12588	1182	66	f	\N	\N	2026-09-19 15:01:52.382595+07	14	auto	\N	\N	\N	{}	\N	\N
12589	1182	46	f	\N	\N	2026-09-19 15:01:52.382595+07	15	auto	\N	\N	\N	{}	\N	\N
12590	1182	84	f	\N	\N	2026-09-19 15:01:52.382595+07	8	auto	\N	\N	\N	{}	\N	\N
12591	1182	48	f	\N	\N	2026-09-19 15:01:52.382595+07	9	auto	\N	\N	\N	{}	\N	\N
12592	1182	77	f	\N	\N	2026-09-19 15:01:52.382595+07	10	auto	\N	\N	\N	{}	\N	\N
12593	1182	57	f	\N	\N	2026-09-19 15:01:52.382595+07	11	auto	\N	\N	\N	{}	\N	\N
12486	1174	130	f	\N	\N	2026-09-19 15:01:50.978508+07	6	auto	\N	\N	\N	{}	\N	\N
12487	1174	131	f	\N	\N	2026-09-19 15:01:50.978508+07	7	auto	\N	\N	\N	{}	\N	\N
12488	1174	87	f	\N	\N	2026-09-19 15:01:50.978508+07	13	auto	\N	\N	\N	{}	\N	\N
12489	1174	70	f	\N	\N	2026-09-19 15:01:50.978508+07	12	auto	\N	\N	\N	{}	\N	\N
12490	1174	43	f	\N	\N	2026-09-19 15:01:50.978508+07	16	auto	\N	\N	\N	{}	\N	\N
12491	1174	45	f	\N	\N	2026-09-19 15:01:50.978508+07	17	auto	\N	\N	\N	{}	\N	\N
12492	1174	48	f	\N	\N	2026-09-19 15:01:50.978508+07	14	auto	\N	\N	\N	{}	\N	\N
12493	1174	46	f	\N	\N	2026-09-19 15:01:50.978508+07	15	auto	\N	\N	\N	{}	\N	\N
12494	1174	78	f	\N	\N	2026-09-19 15:01:50.978508+07	8	auto	\N	\N	\N	{}	\N	\N
12495	1174	54	f	\N	\N	2026-09-19 15:01:50.978508+07	9	auto	\N	\N	\N	{}	\N	\N
12496	1174	89	f	\N	\N	2026-09-19 15:01:50.978508+07	10	auto	\N	\N	\N	{}	\N	\N
12497	1174	28	f	\N	\N	2026-09-19 15:01:50.978508+07	11	auto	\N	\N	\N	{}	\N	\N
12522	1177	145	f	\N	\N	2026-09-19 15:01:51.518515+07	6	auto	\N	\N	\N	{}	\N	\N
12523	1177	119	f	\N	\N	2026-09-19 15:01:51.518515+07	7	auto	\N	\N	\N	{}	\N	\N
12524	1177	73	f	\N	\N	2026-09-19 15:01:51.518515+07	13	auto	\N	\N	\N	{}	\N	\N
12525	1177	5	f	\N	\N	2026-09-19 15:01:51.518515+07	12	auto	\N	\N	\N	{}	\N	\N
12526	1177	63	f	\N	\N	2026-09-19 15:01:51.518515+07	16	auto	\N	\N	\N	{}	\N	\N
12527	1177	36	f	\N	\N	2026-09-19 15:01:51.518515+07	17	auto	\N	\N	\N	{}	\N	\N
12528	1177	64	f	\N	\N	2026-09-19 15:01:51.518515+07	14	auto	\N	\N	\N	{}	\N	\N
12529	1177	66	f	\N	\N	2026-09-19 15:01:51.518515+07	15	auto	\N	\N	\N	{}	\N	\N
12530	1177	77	f	\N	\N	2026-09-19 15:01:51.518515+07	8	auto	\N	\N	\N	{}	\N	\N
12531	1177	65	f	\N	\N	2026-09-19 15:01:51.518515+07	9	auto	\N	\N	\N	{}	\N	\N
12532	1177	84	f	\N	\N	2026-09-19 15:01:51.518515+07	10	auto	\N	\N	\N	{}	\N	\N
12533	1177	29	f	\N	\N	2026-09-19 15:01:51.518515+07	11	auto	\N	\N	\N	{}	\N	\N
12534	1178	121	f	\N	\N	2026-09-19 15:01:51.526435+07	6	auto	\N	\N	\N	{}	\N	\N
12535	1178	9	f	\N	\N	2026-09-19 15:01:51.526435+07	7	auto	\N	\N	\N	{}	\N	\N
12536	1178	83	f	\N	\N	2026-09-19 15:01:51.526435+07	13	auto	\N	\N	\N	{}	\N	\N
12537	1178	17	f	\N	\N	2026-09-19 15:01:51.526435+07	12	auto	\N	\N	\N	{}	\N	\N
12538	1178	67	f	\N	\N	2026-09-19 15:01:51.526435+07	16	auto	\N	\N	\N	{}	\N	\N
12539	1178	12	f	\N	\N	2026-09-19 15:01:51.526435+07	17	auto	\N	\N	\N	{}	\N	\N
12540	1178	60	f	\N	\N	2026-09-19 15:01:51.526435+07	14	auto	\N	\N	\N	{}	\N	\N
12541	1178	48	f	\N	\N	2026-09-19 15:01:51.526435+07	15	auto	\N	\N	\N	{}	\N	\N
12542	1178	70	f	\N	\N	2026-09-19 15:01:51.526435+07	8	auto	\N	\N	\N	{}	\N	\N
12543	1178	46	f	\N	\N	2026-09-19 15:01:51.526435+07	9	auto	\N	\N	\N	{}	\N	\N
12544	1178	81	f	\N	\N	2026-09-19 15:01:51.526435+07	10	auto	\N	\N	\N	{}	\N	\N
12545	1178	49	f	\N	\N	2026-09-19 15:01:51.526435+07	11	auto	\N	\N	\N	{}	\N	\N
12546	1179	95	f	\N	\N	2026-09-19 15:01:51.527635+07	6	auto	\N	\N	\N	{}	\N	\N
12547	1179	97	f	\N	\N	2026-09-19 15:01:51.527635+07	7	auto	\N	\N	\N	{}	\N	\N
12548	1179	85	f	\N	\N	2026-09-19 15:01:51.527635+07	13	auto	\N	\N	\N	{}	\N	\N
12549	1179	78	f	\N	\N	2026-09-19 15:01:51.527635+07	12	auto	\N	\N	\N	{}	\N	\N
12550	1179	69	f	\N	\N	2026-09-19 15:01:51.527635+07	16	auto	\N	\N	\N	{}	\N	\N
12551	1179	24	f	\N	\N	2026-09-19 15:01:51.527635+07	17	auto	\N	\N	\N	{}	\N	\N
12552	1179	54	f	\N	\N	2026-09-19 15:01:51.527635+07	14	auto	\N	\N	\N	{}	\N	\N
12553	1179	58	f	\N	\N	2026-09-19 15:01:51.527635+07	15	auto	\N	\N	\N	{}	\N	\N
12554	1179	4	f	\N	\N	2026-09-19 15:01:51.527635+07	8	auto	\N	\N	\N	{}	\N	\N
12555	1179	16	f	\N	\N	2026-09-19 15:01:51.527635+07	9	auto	\N	\N	\N	{}	\N	\N
12556	1179	88	f	\N	\N	2026-09-19 15:01:51.527635+07	10	auto	\N	\N	\N	{}	\N	\N
12557	1179	52	f	\N	\N	2026-09-19 15:01:51.527635+07	11	auto	\N	\N	\N	{}	\N	\N
12594	1183	136	f	\N	\N	2026-09-19 15:01:52.534357+07	6	auto	\N	\N	\N	{}	\N	\N
12595	1183	108	f	\N	\N	2026-09-19 15:01:52.534357+07	7	auto	\N	\N	\N	{}	\N	\N
12596	1183	73	f	\N	\N	2026-09-19 15:01:52.534357+07	13	auto	\N	\N	\N	{}	\N	\N
12597	1183	17	f	\N	\N	2026-09-19 15:01:52.534357+07	12	auto	\N	\N	\N	{}	\N	\N
12598	1183	61	f	\N	\N	2026-09-19 15:01:52.534357+07	16	auto	\N	\N	\N	{}	\N	\N
12599	1183	63	f	\N	\N	2026-09-19 15:01:52.534357+07	17	auto	\N	\N	\N	{}	\N	\N
12600	1183	60	f	\N	\N	2026-09-19 15:01:52.534357+07	14	auto	\N	\N	\N	{}	\N	\N
12601	1183	58	f	\N	\N	2026-09-19 15:01:52.534357+07	15	auto	\N	\N	\N	{}	\N	\N
12602	1183	81	f	\N	\N	2026-09-19 15:01:52.534357+07	8	auto	\N	\N	\N	{}	\N	\N
12603	1183	36	f	\N	\N	2026-09-19 15:01:52.534357+07	9	auto	\N	\N	\N	{}	\N	\N
12604	1183	88	f	\N	\N	2026-09-19 15:01:52.534357+07	10	auto	\N	\N	\N	{}	\N	\N
12605	1183	52	f	\N	\N	2026-09-19 15:01:52.534357+07	11	auto	\N	\N	\N	{}	\N	\N
12511	1176	102	f	\N	\N	2026-09-19 15:01:51.277248+07	7	auto	\N	\N	\N	{}	\N	\N
12512	1176	71	f	\N	\N	2026-09-19 15:01:51.277248+07	13	auto	\N	\N	\N	{}	\N	\N
12513	1176	76	f	\N	\N	2026-09-19 15:01:51.277248+07	12	auto	\N	\N	\N	{}	\N	\N
12514	1176	55	f	\N	\N	2026-09-19 15:01:51.277248+07	16	auto	\N	\N	\N	{}	\N	\N
12515	1176	57	f	\N	\N	2026-09-19 15:01:51.277248+07	17	auto	\N	\N	\N	{}	\N	\N
12516	1176	37	f	\N	\N	2026-09-19 15:01:51.277248+07	14	auto	\N	\N	\N	{}	\N	\N
12517	1176	42	f	\N	\N	2026-09-19 15:01:51.277248+07	15	auto	\N	\N	\N	{}	\N	\N
12518	1176	90	f	\N	\N	2026-09-19 15:01:51.277248+07	8	auto	\N	\N	\N	{}	\N	\N
12519	1176	25	f	\N	\N	2026-09-19 15:01:51.277248+07	9	auto	\N	\N	\N	{}	\N	\N
12520	1176	75	f	\N	\N	2026-09-19 15:01:51.277248+07	10	auto	\N	\N	\N	{}	\N	\N
12521	1176	61	f	\N	\N	2026-09-19 15:01:51.277248+07	11	auto	\N	\N	\N	{}	\N	\N
12608	1184	83	f	\N	\N	2026-09-19 15:01:52.781038+07	13	auto	\N	\N	\N	{}	\N	\N
12609	1184	78	f	\N	\N	2026-09-19 15:01:52.781038+07	12	auto	\N	\N	\N	{}	\N	\N
12610	1184	65	f	\N	\N	2026-09-19 15:01:52.781038+07	16	auto	\N	\N	\N	{}	\N	\N
12611	1184	67	f	\N	\N	2026-09-19 15:01:52.781038+07	17	auto	\N	\N	\N	{}	\N	\N
12612	1184	54	f	\N	\N	2026-09-19 15:01:52.781038+07	14	auto	\N	\N	\N	{}	\N	\N
12613	1184	37	f	\N	\N	2026-09-19 15:01:52.781038+07	15	auto	\N	\N	\N	{}	\N	\N
12614	1184	82	f	\N	\N	2026-09-19 15:01:52.781038+07	8	auto	\N	\N	\N	{}	\N	\N
12615	1184	42	f	\N	\N	2026-09-19 15:01:52.781038+07	9	auto	\N	\N	\N	{}	\N	\N
12616	1184	4	f	\N	\N	2026-09-19 15:01:52.781038+07	10	auto	\N	\N	\N	{}	\N	\N
12617	1184	12	f	\N	\N	2026-09-19 15:01:52.781038+07	11	auto	\N	\N	\N	{}	\N	\N
12618	1185	149	f	\N	\N	2026-09-19 15:01:52.788986+07	6	auto	\N	\N	\N	{}	\N	\N
12619	1185	101	f	\N	\N	2026-09-19 15:01:52.788986+07	7	auto	\N	\N	\N	{}	\N	\N
12620	1185	85	f	\N	\N	2026-09-19 15:01:52.788986+07	13	auto	\N	\N	\N	{}	\N	\N
12621	1185	72	f	\N	\N	2026-09-19 15:01:52.788986+07	12	auto	\N	\N	\N	{}	\N	\N
12622	1185	49	f	\N	\N	2026-09-19 15:01:52.788986+07	16	auto	\N	\N	\N	{}	\N	\N
12623	1185	24	f	\N	\N	2026-09-19 15:01:52.788986+07	17	auto	\N	\N	\N	{}	\N	\N
12624	1185	64	f	\N	\N	2026-09-19 15:01:52.788986+07	14	auto	\N	\N	\N	{}	\N	\N
12625	1185	25	f	\N	\N	2026-09-19 15:01:52.788986+07	15	auto	\N	\N	\N	{}	\N	\N
12626	1185	32	f	\N	\N	2026-09-19 15:01:52.788986+07	8	auto	\N	\N	\N	{}	\N	\N
12627	1185	16	f	\N	\N	2026-09-19 15:01:52.788986+07	9	auto	\N	\N	\N	{}	\N	\N
12628	1185	90	f	\N	\N	2026-09-19 15:01:52.788986+07	10	auto	\N	\N	\N	{}	\N	\N
12629	1185	76	f	\N	\N	2026-09-19 15:01:52.788986+07	11	auto	\N	\N	\N	{}	\N	\N
12630	1186	150	f	\N	\N	2026-09-19 15:01:52.790206+07	6	auto	\N	\N	\N	{}	\N	\N
12631	1186	111	f	\N	\N	2026-09-19 15:01:52.790206+07	7	auto	\N	\N	\N	{}	\N	\N
12632	1186	87	f	\N	\N	2026-09-19 15:01:52.790206+07	13	auto	\N	\N	\N	{}	\N	\N
12633	1186	5	f	\N	\N	2026-09-19 15:01:52.790206+07	12	auto	\N	\N	\N	{}	\N	\N
12634	1186	69	f	\N	\N	2026-09-19 15:01:52.790206+07	16	auto	\N	\N	\N	{}	\N	\N
12635	1186	41	f	\N	\N	2026-09-19 15:01:52.790206+07	17	auto	\N	\N	\N	{}	\N	\N
12636	1186	46	f	\N	\N	2026-09-19 15:01:52.790206+07	14	auto	\N	\N	\N	{}	\N	\N
12637	1186	48	f	\N	\N	2026-09-19 15:01:52.790206+07	15	auto	\N	\N	\N	{}	\N	\N
12638	1186	29	f	\N	\N	2026-09-19 15:01:52.790206+07	8	auto	\N	\N	\N	{}	\N	\N
12639	1186	84	f	\N	\N	2026-09-19 15:01:52.790206+07	9	auto	\N	\N	\N	{}	\N	\N
12640	1186	28	f	\N	\N	2026-09-19 15:01:52.790206+07	10	auto	\N	\N	\N	{}	\N	\N
12641	1186	43	f	\N	\N	2026-09-19 15:01:52.790206+07	11	auto	\N	\N	\N	{}	\N	\N
15863	1450	22	f	\N	\N	2026-09-19 15:20:07.706585+07	6	auto	\N	\N	\N	{}	\N	\N
15864	1450	95	f	\N	\N	2026-09-19 15:20:07.706585+07	7	auto	\N	\N	\N	{}	\N	\N
15865	1450	71	f	\N	\N	2026-09-19 15:20:07.706585+07	13	auto	\N	\N	\N	{}	\N	\N
15866	1450	76	f	\N	\N	2026-09-19 15:20:07.706585+07	12	auto	\N	\N	\N	{}	\N	\N
15867	1450	47	f	\N	\N	2026-09-19 15:20:07.706585+07	16	auto	\N	\N	\N	{}	\N	\N
15868	1450	51	f	\N	\N	2026-09-19 15:20:07.706585+07	17	auto	\N	\N	\N	{}	\N	\N
15869	1450	46	f	\N	\N	2026-09-19 15:20:07.706585+07	14	auto	\N	\N	\N	{}	\N	\N
15870	1450	52	f	\N	\N	2026-09-19 15:20:07.706585+07	15	auto	\N	\N	\N	{}	\N	\N
15871	1450	73	f	\N	\N	2026-09-19 15:20:07.706585+07	8	auto	\N	\N	\N	{}	\N	\N
15872	1450	53	f	\N	\N	2026-09-19 15:20:07.706585+07	9	auto	\N	\N	\N	{}	\N	\N
15873	1450	70	f	\N	\N	2026-09-19 15:20:07.706585+07	10	auto	\N	\N	\N	{}	\N	\N
15874	1450	17	f	\N	\N	2026-09-19 15:20:07.706585+07	11	auto	\N	\N	\N	{}	\N	\N
15887	1452	35	f	\N	\N	2026-09-19 15:20:07.918886+07	6	auto	\N	\N	\N	{}	\N	\N
15888	1452	108	f	\N	\N	2026-09-19 15:20:07.918886+07	7	auto	\N	\N	\N	{}	\N	\N
15889	1452	85	f	\N	\N	2026-09-19 15:20:07.918886+07	13	auto	\N	\N	\N	{}	\N	\N
15890	1452	88	f	\N	\N	2026-09-19 15:20:07.918886+07	12	auto	\N	\N	\N	{}	\N	\N
15891	1452	63	f	\N	\N	2026-09-19 15:20:07.918886+07	16	auto	\N	\N	\N	{}	\N	\N
15892	1452	65	f	\N	\N	2026-09-19 15:20:07.918886+07	17	auto	\N	\N	\N	{}	\N	\N
15893	1452	64	f	\N	\N	2026-09-19 15:20:07.918886+07	14	auto	\N	\N	\N	{}	\N	\N
15894	1452	66	f	\N	\N	2026-09-19 15:20:07.918886+07	15	auto	\N	\N	\N	{}	\N	\N
15895	1452	77	f	\N	\N	2026-09-19 15:20:07.918886+07	8	auto	\N	\N	\N	{}	\N	\N
15896	1452	67	f	\N	\N	2026-09-19 15:20:07.918886+07	9	auto	\N	\N	\N	{}	\N	\N
15897	1452	90	f	\N	\N	2026-09-19 15:20:07.918886+07	10	auto	\N	\N	\N	{}	\N	\N
15898	1452	37	f	\N	\N	2026-09-19 15:20:07.918886+07	11	auto	\N	\N	\N	{}	\N	\N
16151	1474	149	f	\N	\N	2026-09-19 15:20:11.111061+07	6	auto	\N	\N	\N	{}	\N	\N
16152	1474	102	f	\N	\N	2026-09-19 15:20:11.111061+07	7	auto	\N	\N	\N	{}	\N	\N
16153	1474	71	f	\N	\N	2026-09-19 15:20:11.111061+07	13	auto	\N	\N	\N	{}	\N	\N
16154	1474	88	f	\N	\N	2026-09-19 15:20:11.111061+07	12	auto	\N	\N	\N	{}	\N	\N
16155	1474	45	f	\N	\N	2026-09-19 15:20:11.111061+07	16	auto	\N	\N	\N	{}	\N	\N
16156	1474	43	f	\N	\N	2026-09-19 15:20:11.111061+07	17	auto	\N	\N	\N	{}	\N	\N
16157	1474	66	f	\N	\N	2026-09-19 15:20:11.111061+07	14	auto	\N	\N	\N	{}	\N	\N
16158	1474	37	f	\N	\N	2026-09-19 15:20:11.111061+07	15	auto	\N	\N	\N	{}	\N	\N
16159	1474	73	f	\N	\N	2026-09-19 15:20:11.111061+07	8	auto	\N	\N	\N	{}	\N	\N
16160	1474	47	f	\N	\N	2026-09-19 15:20:11.111061+07	9	auto	\N	\N	\N	{}	\N	\N
16161	1474	84	f	\N	\N	2026-09-19 15:20:11.111061+07	10	auto	\N	\N	\N	{}	\N	\N
16162	1474	42	f	\N	\N	2026-09-19 15:20:11.111061+07	11	auto	\N	\N	\N	{}	\N	\N
16163	1475	150	f	\N	\N	2026-09-19 15:20:11.118921+07	6	auto	\N	\N	\N	{}	\N	\N
16164	1475	95	f	\N	\N	2026-09-19 15:20:11.118921+07	7	auto	\N	\N	\N	{}	\N	\N
16165	1475	75	f	\N	\N	2026-09-19 15:20:11.118921+07	13	auto	\N	\N	\N	{}	\N	\N
16166	1475	90	f	\N	\N	2026-09-19 15:20:11.118921+07	12	auto	\N	\N	\N	{}	\N	\N
16167	1475	51	f	\N	\N	2026-09-19 15:20:11.118921+07	16	auto	\N	\N	\N	{}	\N	\N
16168	1475	53	f	\N	\N	2026-09-19 15:20:11.118921+07	17	auto	\N	\N	\N	{}	\N	\N
16169	1475	48	f	\N	\N	2026-09-19 15:20:11.118921+07	14	auto	\N	\N	\N	{}	\N	\N
16170	1475	25	f	\N	\N	2026-09-19 15:20:11.118921+07	15	auto	\N	\N	\N	{}	\N	\N
16171	1475	78	f	\N	\N	2026-09-19 15:20:11.118921+07	8	auto	\N	\N	\N	{}	\N	\N
16172	1475	29	f	\N	\N	2026-09-19 15:20:11.118921+07	9	auto	\N	\N	\N	{}	\N	\N
16173	1475	83	f	\N	\N	2026-09-19 15:20:11.118921+07	10	auto	\N	\N	\N	{}	\N	\N
16174	1475	55	f	\N	\N	2026-09-19 15:20:11.118921+07	11	auto	\N	\N	\N	{}	\N	\N
16175	1476	22	f	\N	\N	2026-09-19 15:20:11.120061+07	6	auto	\N	\N	\N	{}	\N	\N
16176	1476	107	f	\N	\N	2026-09-19 15:20:11.120061+07	7	auto	\N	\N	\N	{}	\N	\N
16177	1476	32	f	\N	\N	2026-09-19 15:20:11.120061+07	13	auto	\N	\N	\N	{}	\N	\N
16178	1476	76	f	\N	\N	2026-09-19 15:20:11.120061+07	12	auto	\N	\N	\N	{}	\N	\N
16179	1476	57	f	\N	\N	2026-09-19 15:20:11.120061+07	16	auto	\N	\N	\N	{}	\N	\N
16180	1476	61	f	\N	\N	2026-09-19 15:20:11.120061+07	17	auto	\N	\N	\N	{}	\N	\N
16181	1476	46	f	\N	\N	2026-09-19 15:20:11.120061+07	14	auto	\N	\N	\N	{}	\N	\N
16182	1476	52	f	\N	\N	2026-09-19 15:20:11.120061+07	15	auto	\N	\N	\N	{}	\N	\N
16183	1476	77	f	\N	\N	2026-09-19 15:20:11.120061+07	8	auto	\N	\N	\N	{}	\N	\N
16184	1476	63	f	\N	\N	2026-09-19 15:20:11.120061+07	9	auto	\N	\N	\N	{}	\N	\N
16185	1476	5	f	\N	\N	2026-09-19 15:20:11.120061+07	10	auto	\N	\N	\N	{}	\N	\N
16186	1476	82	f	\N	\N	2026-09-19 15:20:11.120061+07	11	auto	\N	\N	\N	{}	\N	\N
16115	1471	145	f	\N	\N	2026-09-19 15:20:10.625685+07	6	auto	\N	\N	\N	{}	\N	\N
16116	1471	106	f	\N	\N	2026-09-19 15:20:10.625685+07	7	auto	\N	\N	\N	{}	\N	\N
16117	1471	87	f	\N	\N	2026-09-19 15:20:10.625685+07	13	auto	\N	\N	\N	{}	\N	\N
16118	1471	78	f	\N	\N	2026-09-19 15:20:10.625685+07	12	auto	\N	\N	\N	{}	\N	\N
16119	1471	65	f	\N	\N	2026-09-19 15:20:10.625685+07	16	auto	\N	\N	\N	{}	\N	\N
16120	1471	67	f	\N	\N	2026-09-19 15:20:10.625685+07	17	auto	\N	\N	\N	{}	\N	\N
16121	1471	46	f	\N	\N	2026-09-19 15:20:10.625685+07	14	auto	\N	\N	\N	{}	\N	\N
16122	1471	25	f	\N	\N	2026-09-19 15:20:10.625685+07	15	auto	\N	\N	\N	{}	\N	\N
16123	1471	29	f	\N	\N	2026-09-19 15:20:10.625685+07	8	auto	\N	\N	\N	{}	\N	\N
16124	1471	76	f	\N	\N	2026-09-19 15:20:10.625685+07	9	auto	\N	\N	\N	{}	\N	\N
16125	1471	81	f	\N	\N	2026-09-19 15:20:10.625685+07	10	auto	\N	\N	\N	{}	\N	\N
16126	1471	36	f	\N	\N	2026-09-19 15:20:10.625685+07	11	auto	\N	\N	\N	{}	\N	\N
15899	1453	109	f	\N	\N	2026-09-19 15:20:08.105805+07	6	auto	\N	\N	\N	{}	\N	\N
15900	1453	111	f	\N	\N	2026-09-19 15:20:08.105805+07	7	auto	\N	\N	\N	{}	\N	\N
15901	1453	87	f	\N	\N	2026-09-19 15:20:08.105805+07	13	auto	\N	\N	\N	{}	\N	\N
15902	1453	82	f	\N	\N	2026-09-19 15:20:08.105805+07	12	auto	\N	\N	\N	{}	\N	\N
15903	1453	36	f	\N	\N	2026-09-19 15:20:08.105805+07	16	auto	\N	\N	\N	{}	\N	\N
15904	1453	49	f	\N	\N	2026-09-19 15:20:08.105805+07	17	auto	\N	\N	\N	{}	\N	\N
15905	1453	42	f	\N	\N	2026-09-19 15:20:08.105805+07	14	auto	\N	\N	\N	{}	\N	\N
15906	1453	48	f	\N	\N	2026-09-19 15:20:08.105805+07	15	auto	\N	\N	\N	{}	\N	\N
15907	1453	5	f	\N	\N	2026-09-19 15:20:08.105805+07	8	auto	\N	\N	\N	{}	\N	\N
15908	1453	29	f	\N	\N	2026-09-19 15:20:08.105805+07	9	auto	\N	\N	\N	{}	\N	\N
15909	1453	81	f	\N	\N	2026-09-19 15:20:08.105805+07	10	auto	\N	\N	\N	{}	\N	\N
15910	1453	69	f	\N	\N	2026-09-19 15:20:08.105805+07	11	auto	\N	\N	\N	{}	\N	\N
15911	1454	112	f	\N	\N	2026-09-19 15:20:08.113722+07	6	auto	\N	\N	\N	{}	\N	\N
15912	1454	113	f	\N	\N	2026-09-19 15:20:08.113722+07	7	auto	\N	\N	\N	{}	\N	\N
15913	1454	89	f	\N	\N	2026-09-19 15:20:08.113722+07	13	auto	\N	\N	\N	{}	\N	\N
15914	1454	78	f	\N	\N	2026-09-19 15:20:08.113722+07	12	auto	\N	\N	\N	{}	\N	\N
15915	1454	12	f	\N	\N	2026-09-19 15:20:08.113722+07	16	auto	\N	\N	\N	{}	\N	\N
15916	1454	24	f	\N	\N	2026-09-19 15:20:08.113722+07	17	auto	\N	\N	\N	{}	\N	\N
15917	1454	54	f	\N	\N	2026-09-19 15:20:08.113722+07	14	auto	\N	\N	\N	{}	\N	\N
15918	1454	46	f	\N	\N	2026-09-19 15:20:08.113722+07	15	auto	\N	\N	\N	{}	\N	\N
15919	1454	91	f	\N	\N	2026-09-19 15:20:08.113722+07	8	auto	\N	\N	\N	{}	\N	\N
15920	1454	4	f	\N	\N	2026-09-19 15:20:08.113722+07	9	auto	\N	\N	\N	{}	\N	\N
15921	1454	17	f	\N	\N	2026-09-19 15:20:08.113722+07	10	auto	\N	\N	\N	{}	\N	\N
15922	1454	70	f	\N	\N	2026-09-19 15:20:08.113722+07	11	auto	\N	\N	\N	{}	\N	\N
15923	1455	114	f	\N	\N	2026-09-19 15:20:08.114754+07	6	auto	\N	\N	\N	{}	\N	\N
15924	1455	115	f	\N	\N	2026-09-19 15:20:08.114754+07	7	auto	\N	\N	\N	{}	\N	\N
15925	1455	16	f	\N	\N	2026-09-19 15:20:08.114754+07	13	auto	\N	\N	\N	{}	\N	\N
15926	1455	76	f	\N	\N	2026-09-19 15:20:08.114754+07	12	auto	\N	\N	\N	{}	\N	\N
15927	1455	41	f	\N	\N	2026-09-19 15:20:08.114754+07	16	auto	\N	\N	\N	{}	\N	\N
15928	1455	43	f	\N	\N	2026-09-19 15:20:08.114754+07	17	auto	\N	\N	\N	{}	\N	\N
15929	1455	52	f	\N	\N	2026-09-19 15:20:08.114754+07	14	auto	\N	\N	\N	{}	\N	\N
15930	1455	25	f	\N	\N	2026-09-19 15:20:08.114754+07	15	auto	\N	\N	\N	{}	\N	\N
15931	1455	72	f	\N	\N	2026-09-19 15:20:08.114754+07	8	auto	\N	\N	\N	{}	\N	\N
15932	1455	60	f	\N	\N	2026-09-19 15:20:08.114754+07	9	auto	\N	\N	\N	{}	\N	\N
15933	1455	28	f	\N	\N	2026-09-19 15:20:08.114754+07	10	auto	\N	\N	\N	{}	\N	\N
15934	1455	45	f	\N	\N	2026-09-19 15:20:08.114754+07	11	auto	\N	\N	\N	{}	\N	\N
15935	1456	117	f	\N	\N	2026-09-19 15:20:08.505331+07	6	auto	\N	\N	\N	{}	\N	\N
15936	1456	118	f	\N	\N	2026-09-19 15:20:08.505331+07	7	auto	\N	\N	\N	{}	\N	\N
15937	1456	32	f	\N	\N	2026-09-19 15:20:08.505331+07	13	auto	\N	\N	\N	{}	\N	\N
15938	1456	88	f	\N	\N	2026-09-19 15:20:08.505331+07	12	auto	\N	\N	\N	{}	\N	\N
15939	1456	47	f	\N	\N	2026-09-19 15:20:08.505331+07	16	auto	\N	\N	\N	{}	\N	\N
15940	1456	51	f	\N	\N	2026-09-19 15:20:08.505331+07	17	auto	\N	\N	\N	{}	\N	\N
15941	1456	58	f	\N	\N	2026-09-19 15:20:08.505331+07	14	auto	\N	\N	\N	{}	\N	\N
15942	1456	64	f	\N	\N	2026-09-19 15:20:08.505331+07	15	auto	\N	\N	\N	{}	\N	\N
15943	1456	71	f	\N	\N	2026-09-19 15:20:08.505331+07	8	auto	\N	\N	\N	{}	\N	\N
15944	1456	73	f	\N	\N	2026-09-19 15:20:08.505331+07	9	auto	\N	\N	\N	{}	\N	\N
15945	1456	84	f	\N	\N	2026-09-19 15:20:08.505331+07	10	auto	\N	\N	\N	{}	\N	\N
15946	1456	37	f	\N	\N	2026-09-19 15:20:08.505331+07	11	auto	\N	\N	\N	{}	\N	\N
16019	1463	135	f	\N	\N	2026-09-19 15:20:09.453698+07	6	auto	\N	\N	\N	{}	\N	\N
16020	1463	8	f	\N	\N	2026-09-19 15:20:09.453698+07	7	auto	\N	\N	\N	{}	\N	\N
16021	1463	75	f	\N	\N	2026-09-19 15:20:09.453698+07	13	auto	\N	\N	\N	{}	\N	\N
16022	1463	17	f	\N	\N	2026-09-19 15:20:09.453698+07	12	auto	\N	\N	\N	{}	\N	\N
16023	1463	53	f	\N	\N	2026-09-19 15:20:09.453698+07	16	auto	\N	\N	\N	{}	\N	\N
16024	1463	55	f	\N	\N	2026-09-19 15:20:09.453698+07	17	auto	\N	\N	\N	{}	\N	\N
16025	1463	46	f	\N	\N	2026-09-19 15:20:09.453698+07	14	auto	\N	\N	\N	{}	\N	\N
16026	1463	25	f	\N	\N	2026-09-19 15:20:09.453698+07	15	auto	\N	\N	\N	{}	\N	\N
16027	1463	76	f	\N	\N	2026-09-19 15:20:09.453698+07	8	auto	\N	\N	\N	{}	\N	\N
16028	1463	54	f	\N	\N	2026-09-19 15:20:09.453698+07	9	auto	\N	\N	\N	{}	\N	\N
16029	1463	83	f	\N	\N	2026-09-19 15:20:09.453698+07	10	auto	\N	\N	\N	{}	\N	\N
16030	1463	57	f	\N	\N	2026-09-19 15:20:09.453698+07	11	auto	\N	\N	\N	{}	\N	\N
16031	1464	136	f	\N	\N	2026-09-19 15:20:09.569074+07	6	auto	\N	\N	\N	{}	\N	\N
16032	1464	9	f	\N	\N	2026-09-19 15:20:09.569074+07	7	auto	\N	\N	\N	{}	\N	\N
16033	1464	77	f	\N	\N	2026-09-19 15:20:09.569074+07	13	auto	\N	\N	\N	{}	\N	\N
16034	1464	72	f	\N	\N	2026-09-19 15:20:09.569074+07	12	auto	\N	\N	\N	{}	\N	\N
16035	1464	61	f	\N	\N	2026-09-19 15:20:09.569074+07	16	auto	\N	\N	\N	{}	\N	\N
16036	1464	63	f	\N	\N	2026-09-19 15:20:09.569074+07	17	auto	\N	\N	\N	{}	\N	\N
16037	1464	52	f	\N	\N	2026-09-19 15:20:09.569074+07	14	auto	\N	\N	\N	{}	\N	\N
16038	1464	58	f	\N	\N	2026-09-19 15:20:09.569074+07	15	auto	\N	\N	\N	{}	\N	\N
16039	1464	85	f	\N	\N	2026-09-19 15:20:09.569074+07	8	auto	\N	\N	\N	{}	\N	\N
16040	1464	65	f	\N	\N	2026-09-19 15:20:09.569074+07	9	auto	\N	\N	\N	{}	\N	\N
16041	1464	70	f	\N	\N	2026-09-19 15:20:09.569074+07	10	auto	\N	\N	\N	{}	\N	\N
16042	1464	60	f	\N	\N	2026-09-19 15:20:09.569074+07	11	auto	\N	\N	\N	{}	\N	\N
16055	1466	138	f	\N	\N	2026-09-19 15:20:09.826397+07	6	auto	\N	\N	\N	{}	\N	\N
16056	1466	97	f	\N	\N	2026-09-19 15:20:09.826397+07	7	auto	\N	\N	\N	{}	\N	\N
16057	1466	32	f	\N	\N	2026-09-19 15:20:09.826397+07	13	auto	\N	\N	\N	{}	\N	\N
16058	1466	90	f	\N	\N	2026-09-19 15:20:09.826397+07	12	auto	\N	\N	\N	{}	\N	\N
16059	1466	69	f	\N	\N	2026-09-19 15:20:09.826397+07	16	auto	\N	\N	\N	{}	\N	\N
16060	1466	12	f	\N	\N	2026-09-19 15:20:09.826397+07	17	auto	\N	\N	\N	{}	\N	\N
16061	1466	42	f	\N	\N	2026-09-19 15:20:09.826397+07	14	auto	\N	\N	\N	{}	\N	\N
16062	1466	48	f	\N	\N	2026-09-19 15:20:09.826397+07	15	auto	\N	\N	\N	{}	\N	\N
16063	1466	89	f	\N	\N	2026-09-19 15:20:09.826397+07	8	auto	\N	\N	\N	{}	\N	\N
16064	1466	4	f	\N	\N	2026-09-19 15:20:09.826397+07	9	auto	\N	\N	\N	{}	\N	\N
16065	1466	29	f	\N	\N	2026-09-19 15:20:09.826397+07	10	auto	\N	\N	\N	{}	\N	\N
16066	1466	78	f	\N	\N	2026-09-19 15:20:09.826397+07	11	auto	\N	\N	\N	{}	\N	\N
16067	1467	139	f	\N	\N	2026-09-19 15:20:10.041988+07	6	auto	\N	\N	\N	{}	\N	\N
16068	1467	99	f	\N	\N	2026-09-19 15:20:10.041988+07	7	auto	\N	\N	\N	{}	\N	\N
16069	1467	91	f	\N	\N	2026-09-19 15:20:10.041988+07	13	auto	\N	\N	\N	{}	\N	\N
16070	1467	5	f	\N	\N	2026-09-19 15:20:10.041988+07	12	auto	\N	\N	\N	{}	\N	\N
16071	1467	24	f	\N	\N	2026-09-19 15:20:10.041988+07	16	auto	\N	\N	\N	{}	\N	\N
16072	1467	41	f	\N	\N	2026-09-19 15:20:10.041988+07	17	auto	\N	\N	\N	{}	\N	\N
16073	1467	25	f	\N	\N	2026-09-19 15:20:10.041988+07	14	auto	\N	\N	\N	{}	\N	\N
16074	1467	46	f	\N	\N	2026-09-19 15:20:10.041988+07	15	auto	\N	\N	\N	{}	\N	\N
16075	1467	82	f	\N	\N	2026-09-19 15:20:10.041988+07	8	auto	\N	\N	\N	{}	\N	\N
16076	1467	76	f	\N	\N	2026-09-19 15:20:10.041988+07	9	auto	\N	\N	\N	{}	\N	\N
15851	1449	150	f	\N	\N	2026-09-19 15:20:07.594983+07	6	auto	\N	\N	\N	{}	\N	\N
15852	1449	102	f	\N	\N	2026-09-19 15:20:07.594983+07	7	auto	\N	\N	\N	{}	\N	\N
15853	1449	16	f	\N	\N	2026-09-19 15:20:07.594983+07	13	auto	\N	\N	\N	{}	\N	\N
15854	1449	29	f	\N	\N	2026-09-19 15:20:07.594983+07	12	auto	\N	\N	\N	{}	\N	\N
15855	1449	41	f	\N	\N	2026-09-19 15:20:07.594983+07	16	auto	\N	\N	\N	{}	\N	\N
15856	1449	43	f	\N	\N	2026-09-19 15:20:07.594983+07	17	auto	\N	\N	\N	{}	\N	\N
15857	1449	54	f	\N	\N	2026-09-19 15:20:07.594983+07	14	auto	\N	\N	\N	{}	\N	\N
15858	1449	48	f	\N	\N	2026-09-19 15:20:07.594983+07	15	auto	\N	\N	\N	{}	\N	\N
15859	1449	78	f	\N	\N	2026-09-19 15:20:07.594983+07	8	auto	\N	\N	\N	{}	\N	\N
15860	1449	5	f	\N	\N	2026-09-19 15:20:07.594983+07	9	auto	\N	\N	\N	{}	\N	\N
15861	1449	28	f	\N	\N	2026-09-19 15:20:07.594983+07	10	auto	\N	\N	\N	{}	\N	\N
15862	1449	45	f	\N	\N	2026-09-19 15:20:07.594983+07	11	auto	\N	\N	\N	{}	\N	\N
15875	1451	34	f	\N	\N	2026-09-19 15:20:07.812683+07	6	auto	\N	\N	\N	{}	\N	\N
15876	1451	107	f	\N	\N	2026-09-19 15:20:07.812683+07	7	auto	\N	\N	\N	{}	\N	\N
15877	1451	75	f	\N	\N	2026-09-19 15:20:07.812683+07	13	auto	\N	\N	\N	{}	\N	\N
15878	1451	72	f	\N	\N	2026-09-19 15:20:07.812683+07	12	auto	\N	\N	\N	{}	\N	\N
15879	1451	55	f	\N	\N	2026-09-19 15:20:07.812683+07	16	auto	\N	\N	\N	{}	\N	\N
15880	1451	57	f	\N	\N	2026-09-19 15:20:07.812683+07	17	auto	\N	\N	\N	{}	\N	\N
15881	1451	60	f	\N	\N	2026-09-19 15:20:07.812683+07	14	auto	\N	\N	\N	{}	\N	\N
15882	1451	25	f	\N	\N	2026-09-19 15:20:07.812683+07	15	auto	\N	\N	\N	{}	\N	\N
15883	1451	84	f	\N	\N	2026-09-19 15:20:07.812683+07	8	auto	\N	\N	\N	{}	\N	\N
15884	1451	58	f	\N	\N	2026-09-19 15:20:07.812683+07	9	auto	\N	\N	\N	{}	\N	\N
15885	1451	83	f	\N	\N	2026-09-19 15:20:07.812683+07	10	auto	\N	\N	\N	{}	\N	\N
15886	1451	61	f	\N	\N	2026-09-19 15:20:07.812683+07	11	auto	\N	\N	\N	{}	\N	\N
15947	1457	119	f	\N	\N	2026-09-19 15:20:08.619389+07	6	auto	\N	\N	\N	{}	\N	\N
15948	1457	121	f	\N	\N	2026-09-19 15:20:08.619389+07	7	auto	\N	\N	\N	{}	\N	\N
15949	1457	75	f	\N	\N	2026-09-19 15:20:08.619389+07	13	auto	\N	\N	\N	{}	\N	\N
15950	1457	90	f	\N	\N	2026-09-19 15:20:08.619389+07	12	auto	\N	\N	\N	{}	\N	\N
15951	1457	53	f	\N	\N	2026-09-19 15:20:08.619389+07	16	auto	\N	\N	\N	{}	\N	\N
15952	1457	55	f	\N	\N	2026-09-19 15:20:08.619389+07	17	auto	\N	\N	\N	{}	\N	\N
15953	1457	66	f	\N	\N	2026-09-19 15:20:08.619389+07	14	auto	\N	\N	\N	{}	\N	\N
15954	1457	42	f	\N	\N	2026-09-19 15:20:08.619389+07	15	auto	\N	\N	\N	{}	\N	\N
15955	1457	29	f	\N	\N	2026-09-19 15:20:08.619389+07	8	auto	\N	\N	\N	{}	\N	\N
15956	1457	5	f	\N	\N	2026-09-19 15:20:08.619389+07	9	auto	\N	\N	\N	{}	\N	\N
15957	1457	83	f	\N	\N	2026-09-19 15:20:08.619389+07	10	auto	\N	\N	\N	{}	\N	\N
15958	1457	57	f	\N	\N	2026-09-19 15:20:08.619389+07	11	auto	\N	\N	\N	{}	\N	\N
15971	1459	125	f	\N	\N	2026-09-19 15:20:08.849861+07	6	auto	\N	\N	\N	{}	\N	\N
15972	1459	126	f	\N	\N	2026-09-19 15:20:08.849861+07	7	auto	\N	\N	\N	{}	\N	\N
15973	1459	87	f	\N	\N	2026-09-19 15:20:08.849861+07	13	auto	\N	\N	\N	{}	\N	\N
15974	1459	70	f	\N	\N	2026-09-19 15:20:08.849861+07	12	auto	\N	\N	\N	{}	\N	\N
15975	1459	67	f	\N	\N	2026-09-19 15:20:08.849861+07	16	auto	\N	\N	\N	{}	\N	\N
15976	1459	36	f	\N	\N	2026-09-19 15:20:08.849861+07	17	auto	\N	\N	\N	{}	\N	\N
15977	1459	54	f	\N	\N	2026-09-19 15:20:08.849861+07	14	auto	\N	\N	\N	{}	\N	\N
15978	1459	25	f	\N	\N	2026-09-19 15:20:08.849861+07	15	auto	\N	\N	\N	{}	\N	\N
15979	1459	72	f	\N	\N	2026-09-19 15:20:08.849861+07	8	auto	\N	\N	\N	{}	\N	\N
15980	1459	76	f	\N	\N	2026-09-19 15:20:08.849861+07	9	auto	\N	\N	\N	{}	\N	\N
15981	1459	81	f	\N	\N	2026-09-19 15:20:08.849861+07	10	auto	\N	\N	\N	{}	\N	\N
15982	1459	49	f	\N	\N	2026-09-19 15:20:08.849861+07	11	auto	\N	\N	\N	{}	\N	\N
15983	1460	127	f	\N	\N	2026-09-19 15:20:09.049881+07	6	auto	\N	\N	\N	{}	\N	\N
15984	1460	129	f	\N	\N	2026-09-19 15:20:09.049881+07	7	auto	\N	\N	\N	{}	\N	\N
15985	1460	89	f	\N	\N	2026-09-19 15:20:09.049881+07	13	auto	\N	\N	\N	{}	\N	\N
15986	1460	88	f	\N	\N	2026-09-19 15:20:09.049881+07	12	auto	\N	\N	\N	{}	\N	\N
15987	1460	69	f	\N	\N	2026-09-19 15:20:09.049881+07	16	auto	\N	\N	\N	{}	\N	\N
15988	1460	12	f	\N	\N	2026-09-19 15:20:09.049881+07	17	auto	\N	\N	\N	{}	\N	\N
15989	1460	60	f	\N	\N	2026-09-19 15:20:09.049881+07	14	auto	\N	\N	\N	{}	\N	\N
15990	1460	52	f	\N	\N	2026-09-19 15:20:09.049881+07	15	auto	\N	\N	\N	{}	\N	\N
15991	1460	91	f	\N	\N	2026-09-19 15:20:09.049881+07	8	auto	\N	\N	\N	{}	\N	\N
15992	1460	4	f	\N	\N	2026-09-19 15:20:09.049881+07	9	auto	\N	\N	\N	{}	\N	\N
15993	1460	84	f	\N	\N	2026-09-19 15:20:09.049881+07	10	auto	\N	\N	\N	{}	\N	\N
15994	1460	58	f	\N	\N	2026-09-19 15:20:09.049881+07	11	auto	\N	\N	\N	{}	\N	\N
15995	1461	130	f	\N	\N	2026-09-19 15:20:09.05791+07	6	auto	\N	\N	\N	{}	\N	\N
15996	1461	131	f	\N	\N	2026-09-19 15:20:09.05791+07	7	auto	\N	\N	\N	{}	\N	\N
15997	1461	16	f	\N	\N	2026-09-19 15:20:09.05791+07	13	auto	\N	\N	\N	{}	\N	\N
15998	1461	90	f	\N	\N	2026-09-19 15:20:09.05791+07	12	auto	\N	\N	\N	{}	\N	\N
15999	1461	24	f	\N	\N	2026-09-19 15:20:09.05791+07	16	auto	\N	\N	\N	{}	\N	\N
16000	1461	41	f	\N	\N	2026-09-19 15:20:09.05791+07	17	auto	\N	\N	\N	{}	\N	\N
16001	1461	64	f	\N	\N	2026-09-19 15:20:09.05791+07	14	auto	\N	\N	\N	{}	\N	\N
16002	1461	37	f	\N	\N	2026-09-19 15:20:09.05791+07	15	auto	\N	\N	\N	{}	\N	\N
16003	1461	29	f	\N	\N	2026-09-19 15:20:09.05791+07	8	auto	\N	\N	\N	{}	\N	\N
16004	1461	66	f	\N	\N	2026-09-19 15:20:09.05791+07	9	auto	\N	\N	\N	{}	\N	\N
16005	1461	28	f	\N	\N	2026-09-19 15:20:09.05791+07	10	auto	\N	\N	\N	{}	\N	\N
16006	1461	43	f	\N	\N	2026-09-19 15:20:09.05791+07	11	auto	\N	\N	\N	{}	\N	\N
16007	1462	132	f	\N	\N	2026-09-19 15:20:09.059126+07	6	auto	\N	\N	\N	{}	\N	\N
16008	1462	133	f	\N	\N	2026-09-19 15:20:09.059126+07	7	auto	\N	\N	\N	{}	\N	\N
16009	1462	71	f	\N	\N	2026-09-19 15:20:09.059126+07	13	auto	\N	\N	\N	{}	\N	\N
16010	1462	5	f	\N	\N	2026-09-19 15:20:09.059126+07	12	auto	\N	\N	\N	{}	\N	\N
16011	1462	45	f	\N	\N	2026-09-19 15:20:09.059126+07	16	auto	\N	\N	\N	{}	\N	\N
16012	1462	47	f	\N	\N	2026-09-19 15:20:09.059126+07	17	auto	\N	\N	\N	{}	\N	\N
16013	1462	42	f	\N	\N	2026-09-19 15:20:09.059126+07	14	auto	\N	\N	\N	{}	\N	\N
16014	1462	48	f	\N	\N	2026-09-19 15:20:09.059126+07	15	auto	\N	\N	\N	{}	\N	\N
16015	1462	73	f	\N	\N	2026-09-19 15:20:09.059126+07	8	auto	\N	\N	\N	{}	\N	\N
16016	1462	51	f	\N	\N	2026-09-19 15:20:09.059126+07	9	auto	\N	\N	\N	{}	\N	\N
16017	1462	78	f	\N	\N	2026-09-19 15:20:09.059126+07	10	auto	\N	\N	\N	{}	\N	\N
16018	1462	82	f	\N	\N	2026-09-19 15:20:09.059126+07	11	auto	\N	\N	\N	{}	\N	\N
16043	1465	137	f	\N	\N	2026-09-19 15:20:09.697086+07	6	auto	\N	\N	\N	{}	\N	\N
16044	1465	94	f	\N	\N	2026-09-19 15:20:09.697086+07	7	auto	\N	\N	\N	{}	\N	\N
16045	1465	87	f	\N	\N	2026-09-19 15:20:09.697086+07	13	auto	\N	\N	\N	{}	\N	\N
16046	1465	88	f	\N	\N	2026-09-19 15:20:09.697086+07	12	auto	\N	\N	\N	{}	\N	\N
16047	1465	67	f	\N	\N	2026-09-19 15:20:09.697086+07	16	auto	\N	\N	\N	{}	\N	\N
16048	1465	36	f	\N	\N	2026-09-19 15:20:09.697086+07	17	auto	\N	\N	\N	{}	\N	\N
16049	1465	64	f	\N	\N	2026-09-19 15:20:09.697086+07	14	auto	\N	\N	\N	{}	\N	\N
16050	1465	66	f	\N	\N	2026-09-19 15:20:09.697086+07	15	auto	\N	\N	\N	{}	\N	\N
16051	1465	84	f	\N	\N	2026-09-19 15:20:09.697086+07	8	auto	\N	\N	\N	{}	\N	\N
16052	1465	37	f	\N	\N	2026-09-19 15:20:09.697086+07	9	auto	\N	\N	\N	{}	\N	\N
16053	1465	81	f	\N	\N	2026-09-19 15:20:09.697086+07	10	auto	\N	\N	\N	{}	\N	\N
16054	1465	49	f	\N	\N	2026-09-19 15:20:09.697086+07	11	auto	\N	\N	\N	{}	\N	\N
16077	1467	16	f	\N	\N	2026-09-19 15:20:10.041988+07	10	auto	\N	\N	\N	{}	\N	\N
16078	1467	28	f	\N	\N	2026-09-19 15:20:10.041988+07	11	auto	\N	\N	\N	{}	\N	\N
16079	1468	142	f	\N	\N	2026-09-19 15:20:10.050001+07	6	auto	\N	\N	\N	{}	\N	\N
16080	1468	101	f	\N	\N	2026-09-19 15:20:10.050001+07	7	auto	\N	\N	\N	{}	\N	\N
16081	1468	71	f	\N	\N	2026-09-19 15:20:10.050001+07	13	auto	\N	\N	\N	{}	\N	\N
16082	1468	17	f	\N	\N	2026-09-19 15:20:10.050001+07	12	auto	\N	\N	\N	{}	\N	\N
16083	1468	43	f	\N	\N	2026-09-19 15:20:10.050001+07	16	auto	\N	\N	\N	{}	\N	\N
16084	1468	45	f	\N	\N	2026-09-19 15:20:10.050001+07	17	auto	\N	\N	\N	{}	\N	\N
16085	1468	54	f	\N	\N	2026-09-19 15:20:10.050001+07	14	auto	\N	\N	\N	{}	\N	\N
16086	1468	52	f	\N	\N	2026-09-19 15:20:10.050001+07	15	auto	\N	\N	\N	{}	\N	\N
16087	1468	73	f	\N	\N	2026-09-19 15:20:10.050001+07	8	auto	\N	\N	\N	{}	\N	\N
16088	1468	47	f	\N	\N	2026-09-19 15:20:10.050001+07	9	auto	\N	\N	\N	{}	\N	\N
16089	1468	72	f	\N	\N	2026-09-19 15:20:10.050001+07	10	auto	\N	\N	\N	{}	\N	\N
16090	1468	58	f	\N	\N	2026-09-19 15:20:10.050001+07	11	auto	\N	\N	\N	{}	\N	\N
16091	1469	143	f	\N	\N	2026-09-19 15:20:10.051048+07	6	auto	\N	\N	\N	{}	\N	\N
16092	1469	103	f	\N	\N	2026-09-19 15:20:10.051048+07	7	auto	\N	\N	\N	{}	\N	\N
16093	1469	75	f	\N	\N	2026-09-19 15:20:10.051048+07	13	auto	\N	\N	\N	{}	\N	\N
16094	1469	70	f	\N	\N	2026-09-19 15:20:10.051048+07	12	auto	\N	\N	\N	{}	\N	\N
16095	1469	51	f	\N	\N	2026-09-19 15:20:10.051048+07	16	auto	\N	\N	\N	{}	\N	\N
16096	1469	53	f	\N	\N	2026-09-19 15:20:10.051048+07	17	auto	\N	\N	\N	{}	\N	\N
16097	1469	60	f	\N	\N	2026-09-19 15:20:10.051048+07	14	auto	\N	\N	\N	{}	\N	\N
16098	1469	64	f	\N	\N	2026-09-19 15:20:10.051048+07	15	auto	\N	\N	\N	{}	\N	\N
16099	1469	88	f	\N	\N	2026-09-19 15:20:10.051048+07	8	auto	\N	\N	\N	{}	\N	\N
16100	1469	66	f	\N	\N	2026-09-19 15:20:10.051048+07	9	auto	\N	\N	\N	{}	\N	\N
16101	1469	83	f	\N	\N	2026-09-19 15:20:10.051048+07	10	auto	\N	\N	\N	{}	\N	\N
16102	1469	55	f	\N	\N	2026-09-19 15:20:10.051048+07	11	auto	\N	\N	\N	{}	\N	\N
16139	1473	148	f	\N	\N	2026-09-19 15:20:10.891229+07	6	auto	\N	\N	\N	{}	\N	\N
16140	1473	96	f	\N	\N	2026-09-19 15:20:10.891229+07	7	auto	\N	\N	\N	{}	\N	\N
16141	1473	16	f	\N	\N	2026-09-19 15:20:10.891229+07	13	auto	\N	\N	\N	{}	\N	\N
16142	1473	17	f	\N	\N	2026-09-19 15:20:10.891229+07	12	auto	\N	\N	\N	{}	\N	\N
16143	1473	24	f	\N	\N	2026-09-19 15:20:10.891229+07	16	auto	\N	\N	\N	{}	\N	\N
16144	1473	41	f	\N	\N	2026-09-19 15:20:10.891229+07	17	auto	\N	\N	\N	{}	\N	\N
16145	1473	58	f	\N	\N	2026-09-19 15:20:10.891229+07	14	auto	\N	\N	\N	{}	\N	\N
16146	1473	60	f	\N	\N	2026-09-19 15:20:10.891229+07	15	auto	\N	\N	\N	{}	\N	\N
16147	1473	70	f	\N	\N	2026-09-19 15:20:10.891229+07	8	auto	\N	\N	\N	{}	\N	\N
16148	1473	64	f	\N	\N	2026-09-19 15:20:10.891229+07	9	auto	\N	\N	\N	{}	\N	\N
16149	1473	91	f	\N	\N	2026-09-19 15:20:10.891229+07	10	auto	\N	\N	\N	{}	\N	\N
16150	1473	28	f	\N	\N	2026-09-19 15:20:10.891229+07	11	auto	\N	\N	\N	{}	\N	\N
16103	1470	144	f	\N	\N	2026-09-19 15:20:10.494696+07	6	auto	\N	\N	\N	{}	\N	\N
16104	1470	105	f	\N	\N	2026-09-19 15:20:10.494696+07	7	auto	\N	\N	\N	{}	\N	\N
16105	1470	77	f	\N	\N	2026-09-19 15:20:10.494696+07	13	auto	\N	\N	\N	{}	\N	\N
16106	1470	90	f	\N	\N	2026-09-19 15:20:10.494696+07	12	auto	\N	\N	\N	{}	\N	\N
16107	1470	57	f	\N	\N	2026-09-19 15:20:10.494696+07	16	auto	\N	\N	\N	{}	\N	\N
16108	1470	61	f	\N	\N	2026-09-19 15:20:10.494696+07	17	auto	\N	\N	\N	{}	\N	\N
16109	1470	37	f	\N	\N	2026-09-19 15:20:10.494696+07	14	auto	\N	\N	\N	{}	\N	\N
16110	1470	42	f	\N	\N	2026-09-19 15:20:10.494696+07	15	auto	\N	\N	\N	{}	\N	\N
16111	1470	85	f	\N	\N	2026-09-19 15:20:10.494696+07	8	auto	\N	\N	\N	{}	\N	\N
16112	1470	63	f	\N	\N	2026-09-19 15:20:10.494696+07	9	auto	\N	\N	\N	{}	\N	\N
16113	1470	84	f	\N	\N	2026-09-19 15:20:10.494696+07	10	auto	\N	\N	\N	{}	\N	\N
16114	1470	48	f	\N	\N	2026-09-19 15:20:10.494696+07	11	auto	\N	\N	\N	{}	\N	\N
16127	1472	147	f	\N	\N	2026-09-19 15:20:10.757529+07	6	auto	\N	\N	\N	{}	\N	\N
16128	1472	93	f	\N	\N	2026-09-19 15:20:10.757529+07	7	auto	\N	\N	\N	{}	\N	\N
16129	1472	89	f	\N	\N	2026-09-19 15:20:10.757529+07	13	auto	\N	\N	\N	{}	\N	\N
16130	1472	5	f	\N	\N	2026-09-19 15:20:10.757529+07	12	auto	\N	\N	\N	{}	\N	\N
16131	1472	49	f	\N	\N	2026-09-19 15:20:10.757529+07	16	auto	\N	\N	\N	{}	\N	\N
16132	1472	69	f	\N	\N	2026-09-19 15:20:10.757529+07	17	auto	\N	\N	\N	{}	\N	\N
16133	1472	54	f	\N	\N	2026-09-19 15:20:10.757529+07	14	auto	\N	\N	\N	{}	\N	\N
16134	1472	52	f	\N	\N	2026-09-19 15:20:10.757529+07	15	auto	\N	\N	\N	{}	\N	\N
16135	1472	4	f	\N	\N	2026-09-19 15:20:10.757529+07	8	auto	\N	\N	\N	{}	\N	\N
16136	1472	12	f	\N	\N	2026-09-19 15:20:10.757529+07	9	auto	\N	\N	\N	{}	\N	\N
16137	1472	82	f	\N	\N	2026-09-19 15:20:10.757529+07	10	auto	\N	\N	\N	{}	\N	\N
16138	1472	72	f	\N	\N	2026-09-19 15:20:10.757529+07	11	auto	\N	\N	\N	{}	\N	\N
16187	1477	117	f	\N	\N	2026-09-19 16:45:50.627993+07	1	auto	\N	\N	\N	{}	\N	\N
16188	1477	118	f	\N	\N	2026-09-19 16:45:50.627993+07	2	auto	\N	\N	\N	{}	\N	\N
16189	1477	119	f	\N	\N	2026-09-19 16:45:50.627993+07	3	auto	\N	\N	\N	{}	\N	\N
16190	1477	28	f	\N	\N	2026-09-19 16:45:50.627993+07	4	auto	\N	\N	\N	{}	\N	\N
16191	1477	81	f	\N	\N	2026-09-19 16:45:50.627993+07	5	auto	\N	\N	\N	{}	\N	\N
16192	1478	123	f	\N	\N	2026-09-19 16:45:50.706035+07	1	auto	\N	\N	\N	{}	\N	\N
16193	1478	124	f	\N	\N	2026-09-19 16:45:50.706035+07	2	auto	\N	\N	\N	{}	\N	\N
16194	1478	129	f	\N	\N	2026-09-19 16:45:50.706035+07	3	auto	\N	\N	\N	{}	\N	\N
16195	1478	91	f	\N	\N	2026-09-19 16:45:50.706035+07	4	auto	\N	\N	\N	{}	\N	\N
16196	1478	57	f	\N	\N	2026-09-19 16:45:50.706035+07	5	auto	\N	\N	\N	{}	\N	\N
16197	1479	126	f	\N	\N	2026-09-19 16:45:50.820263+07	1	auto	\N	\N	\N	{}	\N	\N
16198	1479	131	f	\N	\N	2026-09-19 16:45:50.820263+07	2	auto	\N	\N	\N	{}	\N	\N
16199	1479	125	f	\N	\N	2026-09-19 16:45:50.820263+07	3	auto	\N	\N	\N	{}	\N	\N
16200	1479	61	f	\N	\N	2026-09-19 16:45:50.820263+07	4	auto	\N	\N	\N	{}	\N	\N
16201	1479	84	f	\N	\N	2026-09-19 16:45:50.820263+07	5	auto	\N	\N	\N	{}	\N	\N
16202	1480	150	f	\N	\N	2026-09-19 16:45:50.828304+07	1	auto	\N	\N	\N	{}	\N	\N
16203	1480	111	f	\N	\N	2026-09-19 16:45:50.828304+07	2	auto	\N	\N	\N	{}	\N	\N
16204	1480	132	f	\N	\N	2026-09-19 16:45:50.828304+07	3	auto	\N	\N	\N	{}	\N	\N
16205	1480	72	f	\N	\N	2026-09-19 16:45:50.828304+07	4	auto	\N	\N	\N	{}	\N	\N
16206	1480	73	f	\N	\N	2026-09-19 16:45:50.828304+07	5	auto	\N	\N	\N	{}	\N	\N
16207	1481	147	f	\N	\N	2026-09-19 16:45:50.829663+07	1	auto	\N	\N	\N	{}	\N	\N
16208	1481	114	f	\N	\N	2026-09-19 16:45:50.829663+07	2	auto	\N	\N	\N	{}	\N	\N
16209	1481	133	f	\N	\N	2026-09-19 16:45:50.829663+07	3	auto	\N	\N	\N	{}	\N	\N
16210	1481	99	f	\N	\N	2026-09-19 16:45:50.829663+07	4	auto	\N	\N	\N	{}	\N	\N
16211	1481	108	f	\N	\N	2026-09-19 16:45:50.829663+07	5	auto	\N	\N	\N	{}	\N	\N
16212	1482	9	f	\N	\N	2026-09-19 16:45:51.042477+07	1	auto	\N	\N	\N	{}	\N	\N
16213	1482	34	f	\N	\N	2026-09-19 16:45:51.042477+07	2	auto	\N	\N	\N	{}	\N	\N
16214	1482	115	f	\N	\N	2026-09-19 16:45:51.042477+07	3	auto	\N	\N	\N	{}	\N	\N
16215	1482	17	f	\N	\N	2026-09-19 16:45:51.042477+07	4	auto	\N	\N	\N	{}	\N	\N
16216	1482	63	f	\N	\N	2026-09-19 16:45:51.042477+07	5	auto	\N	\N	\N	{}	\N	\N
16217	1483	135	f	\N	\N	2026-09-19 16:45:51.126275+07	1	auto	\N	\N	\N	{}	\N	\N
16218	1483	121	f	\N	\N	2026-09-19 16:45:51.126275+07	2	auto	\N	\N	\N	{}	\N	\N
16219	1483	136	f	\N	\N	2026-09-19 16:45:51.126275+07	3	auto	\N	\N	\N	{}	\N	\N
16220	1483	65	f	\N	\N	2026-09-19 16:45:51.126275+07	4	auto	\N	\N	\N	{}	\N	\N
16221	1483	7	f	\N	\N	2026-09-19 16:45:51.126275+07	5	auto	\N	\N	\N	{}	\N	\N
16222	1484	149	f	\N	\N	2026-09-19 16:45:51.198361+07	1	auto	\N	\N	\N	{}	\N	\N
16223	1484	143	f	\N	\N	2026-09-19 16:45:51.198361+07	2	auto	\N	\N	\N	{}	\N	\N
16224	1484	8	f	\N	\N	2026-09-19 16:45:51.198361+07	3	auto	\N	\N	\N	{}	\N	\N
16225	1484	16	f	\N	\N	2026-09-19 16:45:51.198361+07	4	auto	\N	\N	\N	{}	\N	\N
16226	1484	82	f	\N	\N	2026-09-19 16:45:51.198361+07	5	auto	\N	\N	\N	{}	\N	\N
16227	1485	130	f	\N	\N	2026-09-19 16:45:51.269714+07	1	auto	\N	\N	\N	{}	\N	\N
16228	1485	139	f	\N	\N	2026-09-19 16:45:51.269714+07	2	auto	\N	\N	\N	{}	\N	\N
16229	1485	107	f	\N	\N	2026-09-19 16:45:51.269714+07	3	auto	\N	\N	\N	{}	\N	\N
16230	1485	75	f	\N	\N	2026-09-19 16:45:51.269714+07	4	auto	\N	\N	\N	{}	\N	\N
16231	1485	18	f	\N	\N	2026-09-19 16:45:51.269714+07	5	auto	\N	\N	\N	{}	\N	\N
16232	1486	148	f	\N	\N	2026-09-19 16:45:51.376423+07	1	auto	\N	\N	\N	{}	\N	\N
16233	1486	22	f	\N	\N	2026-09-19 16:45:51.376423+07	2	auto	\N	\N	\N	{}	\N	\N
16234	1486	94	f	\N	\N	2026-09-19 16:45:51.376423+07	3	auto	\N	\N	\N	{}	\N	\N
16235	1486	77	f	\N	\N	2026-09-19 16:45:51.376423+07	4	auto	\N	\N	\N	{}	\N	\N
16236	1486	67	f	\N	\N	2026-09-19 16:45:51.376423+07	5	auto	\N	\N	\N	{}	\N	\N
16237	1487	137	f	\N	\N	2026-09-19 16:45:51.384324+07	1	auto	\N	\N	\N	{}	\N	\N
16238	1487	142	f	\N	\N	2026-09-19 16:45:51.384324+07	2	auto	\N	\N	\N	{}	\N	\N
16239	1487	109	f	\N	\N	2026-09-19 16:45:51.384324+07	3	auto	\N	\N	\N	{}	\N	\N
16240	1487	69	f	\N	\N	2026-09-19 16:45:51.384324+07	4	auto	\N	\N	\N	{}	\N	\N
16241	1487	64	f	\N	\N	2026-09-19 16:45:51.384324+07	5	auto	\N	\N	\N	{}	\N	\N
16242	1488	117	f	\N	\N	2026-09-19 16:45:51.385335+07	1	auto	\N	\N	\N	{}	\N	\N
16243	1488	118	f	\N	\N	2026-09-19 16:45:51.385335+07	2	auto	\N	\N	\N	{}	\N	\N
16244	1488	106	f	\N	\N	2026-09-19 16:45:51.385335+07	3	auto	\N	\N	\N	{}	\N	\N
16245	1488	66	f	\N	\N	2026-09-19 16:45:51.385335+07	4	auto	\N	\N	\N	{}	\N	\N
16246	1488	26	f	\N	\N	2026-09-19 16:45:51.385335+07	5	auto	\N	\N	\N	{}	\N	\N
16247	1489	127	f	\N	\N	2026-09-19 16:45:51.579189+07	1	auto	\N	\N	\N	{}	\N	\N
16248	1489	138	f	\N	\N	2026-09-19 16:45:51.579189+07	2	auto	\N	\N	\N	{}	\N	\N
16249	1489	103	f	\N	\N	2026-09-19 16:45:51.579189+07	3	auto	\N	\N	\N	{}	\N	\N
16250	1489	88	f	\N	\N	2026-09-19 16:45:51.579189+07	4	auto	\N	\N	\N	{}	\N	\N
16251	1489	83	f	\N	\N	2026-09-19 16:45:51.579189+07	5	auto	\N	\N	\N	{}	\N	\N
16252	1490	144	f	\N	\N	2026-09-19 16:45:51.654111+07	1	auto	\N	\N	\N	{}	\N	\N
16253	1490	119	f	\N	\N	2026-09-19 16:45:51.654111+07	2	auto	\N	\N	\N	{}	\N	\N
16254	1490	101	f	\N	\N	2026-09-19 16:45:51.654111+07	3	auto	\N	\N	\N	{}	\N	\N
16255	1490	76	f	\N	\N	2026-09-19 16:45:51.654111+07	4	auto	\N	\N	\N	{}	\N	\N
16256	1490	54	f	\N	\N	2026-09-19 16:45:51.654111+07	5	auto	\N	\N	\N	{}	\N	\N
16257	1491	145	f	\N	\N	2026-09-19 16:45:51.725022+07	1	auto	\N	\N	\N	{}	\N	\N
16258	1491	129	f	\N	\N	2026-09-19 16:45:51.725022+07	2	auto	\N	\N	\N	{}	\N	\N
16259	1491	105	f	\N	\N	2026-09-19 16:45:51.725022+07	3	auto	\N	\N	\N	{}	\N	\N
16260	1491	90	f	\N	\N	2026-09-19 16:45:51.725022+07	4	auto	\N	\N	\N	{}	\N	\N
16261	1491	85	f	\N	\N	2026-09-19 16:45:51.725022+07	5	auto	\N	\N	\N	{}	\N	\N
16267	1493	131	f	\N	\N	2026-09-19 16:45:51.902528+07	1	auto	\N	\N	\N	{}	\N	\N
16268	1493	126	f	\N	\N	2026-09-19 16:45:51.902528+07	2	auto	\N	\N	\N	{}	\N	\N
16269	1493	125	f	\N	\N	2026-09-19 16:45:51.902528+07	3	auto	\N	\N	\N	{}	\N	\N
16270	1493	58	f	\N	\N	2026-09-19 16:45:51.902528+07	4	auto	\N	\N	\N	{}	\N	\N
16271	1493	60	f	\N	\N	2026-09-19 16:45:51.902528+07	5	auto	\N	\N	\N	{}	\N	\N
16272	1494	111	f	\N	\N	2026-09-19 16:45:51.903765+07	1	auto	\N	\N	\N	{}	\N	\N
16273	1494	132	f	\N	\N	2026-09-19 16:45:51.903765+07	2	auto	\N	\N	\N	{}	\N	\N
16274	1494	114	f	\N	\N	2026-09-19 16:45:51.903765+07	3	auto	\N	\N	\N	{}	\N	\N
16275	1494	39	f	\N	\N	2026-09-19 16:45:51.903765+07	4	auto	\N	\N	\N	{}	\N	\N
16276	1494	70	f	\N	\N	2026-09-19 16:45:51.903765+07	5	auto	\N	\N	\N	{}	\N	\N
16277	1495	150	f	\N	\N	2026-09-19 16:45:51.904715+07	1	auto	\N	\N	\N	{}	\N	\N
16278	1495	133	f	\N	\N	2026-09-19 16:45:51.904715+07	2	auto	\N	\N	\N	{}	\N	\N
16279	1495	108	f	\N	\N	2026-09-19 16:45:51.904715+07	3	auto	\N	\N	\N	{}	\N	\N
16280	1495	38	f	\N	\N	2026-09-19 16:45:51.904715+07	4	auto	\N	\N	\N	{}	\N	\N
16281	1495	4	f	\N	\N	2026-09-19 16:45:51.904715+07	5	auto	\N	\N	\N	{}	\N	\N
16282	1496	147	f	\N	\N	2026-09-19 16:45:52.109082+07	1	auto	\N	\N	\N	{}	\N	\N
16283	1496	115	f	\N	\N	2026-09-19 16:45:52.109082+07	2	auto	\N	\N	\N	{}	\N	\N
16284	1496	99	f	\N	\N	2026-09-19 16:45:52.109082+07	3	auto	\N	\N	\N	{}	\N	\N
16285	1496	5	f	\N	\N	2026-09-19 16:45:52.109082+07	4	auto	\N	\N	\N	{}	\N	\N
16286	1496	27	f	\N	\N	2026-09-19 16:45:52.109082+07	5	auto	\N	\N	\N	{}	\N	\N
16302	1500	136	f	\N	\N	2026-09-19 16:45:52.442633+07	1	auto	\N	\N	\N	{}	\N	\N
16303	1500	143	f	\N	\N	2026-09-19 16:45:52.442633+07	2	auto	\N	\N	\N	{}	\N	\N
16304	1500	102	f	\N	\N	2026-09-19 16:45:52.442633+07	3	auto	\N	\N	\N	{}	\N	\N
16305	1500	91	f	\N	\N	2026-09-19 16:45:52.442633+07	4	auto	\N	\N	\N	{}	\N	\N
16306	1500	61	f	\N	\N	2026-09-19 16:45:52.442633+07	5	auto	\N	\N	\N	{}	\N	\N
16307	1501	149	f	\N	\N	2026-09-19 16:45:52.450371+07	1	auto	\N	\N	\N	{}	\N	\N
16308	1501	130	f	\N	\N	2026-09-19 16:45:52.450371+07	2	auto	\N	\N	\N	{}	\N	\N
16309	1501	95	f	\N	\N	2026-09-19 16:45:52.450371+07	3	auto	\N	\N	\N	{}	\N	\N
16310	1501	72	f	\N	\N	2026-09-19 16:45:52.450371+07	4	auto	\N	\N	\N	{}	\N	\N
16311	1501	73	f	\N	\N	2026-09-19 16:45:52.450371+07	5	auto	\N	\N	\N	{}	\N	\N
16312	1502	139	f	\N	\N	2026-09-19 16:45:52.45138+07	1	auto	\N	\N	\N	{}	\N	\N
16313	1502	22	f	\N	\N	2026-09-19 16:45:52.45138+07	2	auto	\N	\N	\N	{}	\N	\N
16314	1502	8	f	\N	\N	2026-09-19 16:45:52.45138+07	3	auto	\N	\N	\N	{}	\N	\N
16315	1502	17	f	\N	\N	2026-09-19 16:45:52.45138+07	4	auto	\N	\N	\N	{}	\N	\N
16316	1502	81	f	\N	\N	2026-09-19 16:45:52.45138+07	5	auto	\N	\N	\N	{}	\N	\N
16332	1506	127	f	\N	\N	2026-09-19 16:45:52.870416+07	1	auto	\N	\N	\N	{}	\N	\N
16333	1506	119	f	\N	\N	2026-09-19 16:45:52.870416+07	2	auto	\N	\N	\N	{}	\N	\N
16334	1506	106	f	\N	\N	2026-09-19 16:45:52.870416+07	3	auto	\N	\N	\N	{}	\N	\N
16335	1506	7	f	\N	\N	2026-09-19 16:45:52.870416+07	4	auto	\N	\N	\N	{}	\N	\N
16336	1506	65	f	\N	\N	2026-09-19 16:45:52.870416+07	5	auto	\N	\N	\N	{}	\N	\N
16262	1492	123	f	\N	\N	2026-09-19 16:45:51.796506+07	1	auto	\N	\N	\N	{}	\N	\N
16263	1492	124	f	\N	\N	2026-09-19 16:45:51.796506+07	2	auto	\N	\N	\N	{}	\N	\N
16264	1492	97	f	\N	\N	2026-09-19 16:45:51.796506+07	3	auto	\N	\N	\N	{}	\N	\N
16265	1492	15	f	\N	\N	2026-09-19 16:45:51.796506+07	4	auto	\N	\N	\N	{}	\N	\N
16266	1492	2	f	\N	\N	2026-09-19 16:45:51.796506+07	5	auto	\N	\N	\N	{}	\N	\N
16327	1505	118	f	\N	\N	2026-09-19 16:45:52.798983+07	1	auto	\N	\N	\N	{}	\N	\N
16328	1505	138	f	\N	\N	2026-09-19 16:45:52.798983+07	2	auto	\N	\N	\N	{}	\N	\N
16329	1505	109	f	\N	\N	2026-09-19 16:45:52.798983+07	3	auto	\N	\N	\N	{}	\N	\N
16330	1505	14	f	\N	\N	2026-09-19 16:45:52.798983+07	4	auto	\N	\N	\N	{}	\N	\N
16331	1505	28	f	\N	\N	2026-09-19 16:45:52.798983+07	5	auto	\N	\N	\N	{}	\N	\N
16287	1497	113	f	\N	\N	2026-09-19 16:45:52.191049+07	1	auto	\N	\N	\N	{}	\N	\N
16288	1497	9	f	\N	\N	2026-09-19 16:45:52.191049+07	2	auto	\N	\N	\N	{}	\N	\N
16289	1497	93	f	\N	\N	2026-09-19 16:45:52.191049+07	3	auto	\N	\N	\N	{}	\N	\N
16290	1497	71	f	\N	\N	2026-09-19 16:45:52.191049+07	4	auto	\N	\N	\N	{}	\N	\N
16291	1497	55	f	\N	\N	2026-09-19 16:45:52.191049+07	5	auto	\N	\N	\N	{}	\N	\N
16322	1504	142	f	\N	\N	2026-09-19 16:45:52.725731+07	1	auto	\N	\N	\N	{}	\N	\N
16323	1504	117	f	\N	\N	2026-09-19 16:45:52.725731+07	2	auto	\N	\N	\N	{}	\N	\N
16324	1504	94	f	\N	\N	2026-09-19 16:45:52.725731+07	3	auto	\N	\N	\N	{}	\N	\N
16325	1504	84	f	\N	\N	2026-09-19 16:45:52.725731+07	4	auto	\N	\N	\N	{}	\N	\N
16326	1504	29	f	\N	\N	2026-09-19 16:45:52.725731+07	5	auto	\N	\N	\N	{}	\N	\N
16292	1498	34	f	\N	\N	2026-09-19 16:45:52.262735+07	1	auto	\N	\N	\N	{}	\N	\N
16293	1498	112	f	\N	\N	2026-09-19 16:45:52.262735+07	2	auto	\N	\N	\N	{}	\N	\N
16294	1498	32	f	\N	\N	2026-09-19 16:45:52.262735+07	3	auto	\N	\N	\N	{}	\N	\N
16295	1498	19	f	\N	\N	2026-09-19 16:45:52.262735+07	4	auto	\N	\N	\N	{}	\N	\N
16296	1498	89	f	\N	\N	2026-09-19 16:45:52.262735+07	5	auto	\N	\N	\N	{}	\N	\N
16337	1507	144	f	\N	\N	2026-09-19 16:45:52.977968+07	1	auto	\N	\N	\N	{}	\N	\N
16338	1507	129	f	\N	\N	2026-09-19 16:45:52.977968+07	2	auto	\N	\N	\N	{}	\N	\N
16339	1507	103	f	\N	\N	2026-09-19 16:45:52.977968+07	3	auto	\N	\N	\N	{}	\N	\N
16340	1507	78	f	\N	\N	2026-09-19 16:45:52.977968+07	4	auto	\N	\N	\N	{}	\N	\N
16341	1507	82	f	\N	\N	2026-09-19 16:45:52.977968+07	5	auto	\N	\N	\N	{}	\N	\N
16342	1508	145	f	\N	\N	2026-09-19 16:45:52.985833+07	1	auto	\N	\N	\N	{}	\N	\N
16343	1508	123	f	\N	\N	2026-09-19 16:45:52.985833+07	2	auto	\N	\N	\N	{}	\N	\N
16344	1508	101	f	\N	\N	2026-09-19 16:45:52.985833+07	3	auto	\N	\N	\N	{}	\N	\N
16345	1508	18	f	\N	\N	2026-09-19 16:45:52.985833+07	4	auto	\N	\N	\N	{}	\N	\N
16346	1508	67	f	\N	\N	2026-09-19 16:45:52.985833+07	5	auto	\N	\N	\N	{}	\N	\N
16347	1509	124	f	\N	\N	2026-09-19 16:45:52.986797+07	1	auto	\N	\N	\N	{}	\N	\N
16348	1509	125	f	\N	\N	2026-09-19 16:45:52.986797+07	2	auto	\N	\N	\N	{}	\N	\N
16349	1509	105	f	\N	\N	2026-09-19 16:45:52.986797+07	3	auto	\N	\N	\N	{}	\N	\N
16350	1509	69	f	\N	\N	2026-09-19 16:45:52.986797+07	4	auto	\N	\N	\N	{}	\N	\N
16351	1509	26	f	\N	\N	2026-09-19 16:45:52.986797+07	5	auto	\N	\N	\N	{}	\N	\N
16297	1499	121	f	\N	\N	2026-09-19 16:45:52.335273+07	1	auto	\N	\N	\N	{}	\N	\N
16298	1499	135	f	\N	\N	2026-09-19 16:45:52.335273+07	2	auto	\N	\N	\N	{}	\N	\N
16299	1499	96	f	\N	\N	2026-09-19 16:45:52.335273+07	3	auto	\N	\N	\N	{}	\N	\N
16300	1499	87	f	\N	\N	2026-09-19 16:45:52.335273+07	4	auto	\N	\N	\N	{}	\N	\N
16301	1499	57	f	\N	\N	2026-09-19 16:45:52.335273+07	5	auto	\N	\N	\N	{}	\N	\N
16317	1503	148	f	\N	\N	2026-09-19 16:45:52.646803+07	1	auto	\N	\N	\N	{}	\N	\N
16318	1503	137	f	\N	\N	2026-09-19 16:45:52.646803+07	2	auto	\N	\N	\N	{}	\N	\N
16319	1503	107	f	\N	\N	2026-09-19 16:45:52.646803+07	3	auto	\N	\N	\N	{}	\N	\N
16320	1503	63	f	\N	\N	2026-09-19 16:45:52.646803+07	4	auto	\N	\N	\N	{}	\N	\N
16321	1503	6	f	\N	\N	2026-09-19 16:45:52.646803+07	5	auto	\N	\N	\N	{}	\N	\N
\.


--
-- Data for Name: duty_posts; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.duty_posts (id, duty_type_id, unit_id, short_name, name, sort_order, is_active, created_at, updated_at, required_permit_type_id, required_weapon_kind, start_time, duration_hours, recovery_sleep_days, per_day, rotation_since, allow_consecutive) FROM stdin;
6	2	\N	ДЧ	Дежурный по части	10	t	2026-08-24 15:32:26.126916+07	2026-09-20 15:35:57.800225+07	10	\N	\N	\N	\N	f	2026-09-20	\N
7	2	\N	ПДЧ	Помощник дежурного по части	20	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:13:43.111598+07	9	\N	\N	\N	\N	f	2026-09-01	\N
18	1	\N	КДС	Командир дежурной смены	10	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:01:06.398093+07	12	pistol	\N	\N	\N	f	\N	\N
19	1	\N	ЗКДС	Заместитель командира дежурной смены	20	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:01:07.622926+07	13	pistol	\N	\N	\N	f	\N	\N
20	1	\N	НПНР	Начальник ПНР	30	t	2026-08-24 15:32:26.126916+07	2026-09-11 23:31:51.758064+07	21	rifle	\N	\N	\N	f	\N	\N
21	1	\N	1	Номер расчета 1	41	t	2026-08-24 15:32:26.126916+07	2026-09-11 23:31:51.758064+07	19	rifle	\N	\N	\N	f	\N	\N
22	1	\N	2	Номер расчета 2	42	t	2026-08-24 15:32:26.126916+07	2026-09-11 23:31:51.758064+07	19	rifle	\N	\N	\N	f	\N	\N
23	1	\N	3	Номер расчета 3	43	t	2026-08-24 15:32:26.126916+07	2026-09-11 23:31:51.758064+07	19	rifle	\N	\N	\N	f	\N	\N
24	1	\N	4	Номер расчета 4	44	t	2026-08-24 15:32:26.126916+07	2026-09-11 23:31:51.758064+07	19	rifle	\N	\N	\N	f	\N	\N
25	1	\N	5	Номер расчета 5	45	t	2026-08-24 15:32:26.126916+07	2026-09-11 23:31:51.758064+07	19	rifle	\N	\N	\N	f	\N	\N
16	2	3	\N	Дневальный по 1-й роте — 1	40	t	2026-08-24 15:32:26.126916+07	2026-09-19 15:20:03.264155+07	18	\N	\N	\N	\N	f	\N	\N
8	2	\N	ДКПП	Дежурный по КПП	50	t	2026-08-24 15:32:26.126916+07	2026-09-20 15:24:23.995342+07	15	\N	\N	\N	\N	f	2026-09-01	\N
2	3	\N	СПОД	Старший помощник оперативного дежурного	20	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:17:04.647185+07	24	\N	\N	\N	\N	f	\N	\N
3	3	\N	ПОД	Помощник оперативного дежурного	30	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:17:04.647185+07	22	\N	\N	\N	\N	f	\N	\N
4	3	\N	СО	Старший оператор	40	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:17:04.647185+07	11	\N	\N	\N	\N	f	\N	\N
5	3	\N	О	Оператор	50	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:17:04.647185+07	20	\N	\N	\N	\N	f	\N	\N
1	3	33	ОД	Оперативный дежурный	10	t	2026-08-24 15:32:26.126916+07	2026-09-26 17:17:04.647185+07	16	\N	\N	\N	\N	f	\N	\N
9	2	\N	ПДКПП	Помощник дежурного по КПП	60	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	14	\N	\N	\N	\N	f	2026-09-01	\N
10	2	\N	ДП	Дежурный по парку	70	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	23	\N	\N	\N	\N	f	2026-09-01	\N
11	2	\N	ПДП	Помощник дежурного по парку	80	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	8	\N	\N	\N	\N	f	2026-09-01	\N
13	2	3	\N	Дежурный по 1-й роте	30	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	17	\N	\N	\N	\N	f	2026-09-01	\N
17	2	3	\N	Дневальный по 1-й роте — 2	40	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	18	\N	\N	\N	\N	f	2026-09-01	\N
12	2	2	\N	Дежурный по 2-й роте	30	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	17	\N	\N	\N	\N	f	2026-09-01	\N
14	2	2	\N	Дневальный по 2-й роте — 1	40	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	18	\N	\N	\N	\N	f	2026-09-01	\N
15	2	2	\N	Дневальный по 2-й роте — 2	40	t	2026-08-24 15:32:26.126916+07	2026-09-19 14:46:58.341842+07	18	\N	\N	\N	\N	f	2026-09-01	\N
26	1	\N	НР6	Номер расчета 6	46	f	2026-08-24 15:39:45.055793+07	2026-09-11 23:31:51.758064+07	19	rifle	\N	\N	\N	f	\N	\N
29	1	\N	ПУД 1	Пост управления доступом 1	52	t	2026-09-13 10:40:56.212302+07	2026-09-13 10:40:56.212302+07	26	\N	08:00:00	10	0	f	\N	\N
30	1	\N	ПУД 2	Пост управления доступом 2	53	t	2026-09-13 10:40:56.212302+07	2026-09-13 10:40:56.212302+07	26	\N	08:00:00	10	0	f	\N	\N
28	1	\N	ПТСО 2	Пост технических средств охраны 2	51	t	2026-09-13 10:40:56.212302+07	2026-09-13 11:19:04.477482+07	25	\N	20:00:00	12	1	t	\N	\N
27	1	\N	ПТСО 1	Пост технических средств охраны 1	50	t	2026-09-13 10:40:56.212302+07	2026-09-13 11:19:04.477482+07	25	\N	08:00:00	12	1	t	\N	\N
33	5	\N	КПАТ	Командир ПАТ	1	t	2026-09-20 19:05:16.545798+07	2026-09-20 19:05:16.545798+07	5	pistol	\N	\N	\N	f	\N	t
\.


--
-- Data for Name: duty_type_permits; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.duty_type_permits (duty_type_id, permit_type_id) FROM stdin;
3	1
2	1
1	2
3	5
2	5
1	5
3	6
2	6
1	6
\.


--
-- Data for Name: duty_type_schedules; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.duty_type_schedules (id, duty_type_id, start_weekday, end_weekday, start_time) FROM stdin;
1	1	5	2	17:30:00
2	1	2	5	17:30:00
\.


--
-- Data for Name: duty_types; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.duty_types (id, code, name, kind, start_time, duration_hours, recovery_sleep_days, recovery_off_days, rest_excludes_weekends, base_weight, is_active, allow_consecutive, holiday_rule, sort_order, order_template) FROM stdin;
3	OD	Оперативное дежурство	daily	10:00:00	24	1	1	f	1.00	t	f	any	40	\N
1	OO	Дежурная смена «Охрана и оборона»	multiday	17:30:00	\N	2	0	t	2.00	t	f	any	20	\N
5	ПАТ	Подразделение АТ	daily	10:00:00	24	1	0	f	1.00	t	t	any	30	\N
2	SN	Суточный наряд	daily	10:30:00	24	1	1	f	1.00	t	f	any	10	{"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Закрепить за личным составом на время несения дежурства следующее оружие:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "{{командир_должность}}\\n{{командир_звание}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}, {"bold": false, "kind": "signature", "text": "{{начальник_штаба_должность}}\\n{{начальник_штаба_звание}}", "align": "left", "posts": [], "right": "{{начальник_штаба}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 18}]}
\.


--
-- Data for Name: order_template_versions; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.order_template_versions (id, duty_type_id, version, template, reason, created_by, created_at) FROM stdin;
1	2	1	{"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "Командир {{часть}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}]}	Настройка	1	2026-09-27 13:47:50.533896+07
2	2	2	{"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Закрепить за личным составом на время несения дежурства следующее оружие:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "Командир {{часть}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}]}	Настройка	1	2026-09-27 13:49:27.218907+07
3	2	3	{"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [6, 7], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Закрепить за личным составом на время несения дежурства следующее оружие:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "Командир {{часть}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}]}	Настройка	1	2026-09-27 13:50:10.544199+07
4	2	4	{"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Закрепить за личным составом на время несения дежурства следующее оружие:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "Командир {{часть}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}]}	Проверка	1	2026-09-27 14:31:45.946747+07
5	2	5	{"page": {"fontSize": 14, "marginTop": 20, "lineHeight": 1, "marginLeft": 30, "marginRight": 15, "marginBottom": 20}, "blocks": [{"bold": true, "kind": "text", "text": "ПРИКАЗ", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "{{часть}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "№ ______                                        {{дата_приказа}}", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": true, "kind": "text", "text": "О назначении наряда «{{вид_наряда}}»", "align": "center", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 12}, {"bold": false, "kind": "text", "text": "Для несения службы в наряде «{{вид_наряда}}» {{период}}", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": false, "spaceBefore": 12}, {"bold": true, "kind": "text", "text": "ПРИКАЗЫВАЮ:", "align": "left", "posts": [], "right": "", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 6}, {"bold": false, "kind": "roster", "text": "Назначить в наряд с {{с}} по {{по}} следующий личный состав:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Личному составу наряда получить личное оружие.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "weapons", "text": "Закрепить за личным составом на время несения дежурства следующее оружие:", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "text", "text": "Контроль за исполнением приказа оставляю за собой.", "align": "justify", "posts": [], "right": "", "format": "list", "indent": 1.25, "numbered": true, "spaceBefore": 0}, {"bold": false, "kind": "signature", "text": "{{командир_должность}}\\n{{командир_звание}}", "align": "left", "posts": [], "right": "{{командир}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 24}, {"bold": false, "kind": "signature", "text": "{{начальник_штаба_должность}}\\n{{начальник_штаба_звание}}", "align": "left", "posts": [], "right": "{{начальник_штаба}}", "format": "list", "indent": 0, "numbered": false, "spaceBefore": 18}]}	Системой: подпись начальника штаба под командиром; должность подписанта (ВРИО)	\N	2026-09-27 14:49:18.755948+07
\.


--
-- Data for Name: post_employees; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.post_employees (post_id, employee_id, note, created_at, created_by) FROM stdin;
\.


--
-- Data for Name: post_rank_weights; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.post_rank_weights (post_id, rank_id, weight) FROM stdin;
6	1	-5
8	1	-5
10	1	-5
13	1	-5
12	1	-5
6	2	-5
8	2	-5
10	2	-5
13	2	-5
12	2	-5
6	3	5
8	3	5
10	3	5
13	3	5
12	3	5
6	4	5
8	4	5
10	4	5
13	4	5
12	4	5
6	5	5
8	5	5
10	5	5
13	5	5
12	5	5
6	6	5
8	6	5
10	6	5
13	6	5
12	6	5
17	1	5
14	1	5
15	1	5
16	1	5
17	2	5
14	2	5
15	2	5
16	2	5
17	3	-3
14	3	-3
15	3	-3
16	3	-3
17	4	-3
14	4	-3
15	4	-3
16	4	-3
17	5	-3
14	5	-3
15	5	-3
16	5	-3
17	6	-3
14	6	-3
15	6	-3
16	6	-3
\.


--
-- Data for Name: post_responsibilities; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.post_responsibilities (post_id, on_date, unit_id, note, assigned_by, assigned_at) FROM stdin;
8	2026-10-21	2	\N	1	2026-09-19 14:23:52.785235+07
1	2026-09-30	33	\N	1	2026-09-20 15:12:10.246877+07
\.


--
-- Data for Name: post_units; Type: TABLE DATA; Schema: duty; Owner: -
--

COPY duty.post_units (post_id, turn, unit_id) FROM stdin;
8	1	3
8	2	2
6	1	33
6	2	4
6	3	5
15	1	2
14	1	2
12	1	2
17	1	3
13	1	3
9	2	2
9	1	3
10	1	2
10	2	3
11	1	2
11	2	3
16	1	3
1	1	33
\.


--
-- Data for Name: documents; Type: TABLE DATA; Schema: parse; Owner: -
--

COPY parse.documents (order_id, blocks, error, extracted_at) FROM stdin;
\.


--
-- Data for Name: phrases; Type: TABLE DATA; Schema: parse; Owner: -
--

COPY parse.phrases (id, kind, target, phrase, created_by, created_at, section_id) FROM stdin;
1	order_permit	\N	о допуске	\N	2026-09-27 19:09:43.766361+07	1
2	order_permit	\N	допустить	\N	2026-09-27 19:09:43.766361+07	1
3	order_permit	\N	допуск к	\N	2026-09-27 19:09:43.766361+07	1
4	order_absence	\N	об убытии	\N	2026-09-27 19:09:43.766361+07	2
5	order_absence	\N	убывшим	\N	2026-09-27 19:09:43.766361+07	2
6	order_absence	\N	убывшими	\N	2026-09-27 19:09:43.766361+07	2
7	order_absence	\N	полагать убывш	\N	2026-09-27 19:09:43.766361+07	2
8	order_absence	\N	об отпуске	\N	2026-09-27 19:09:43.766361+07	2
9	order_absence	\N	о командировании	\N	2026-09-27 19:09:43.766361+07	2
10	absence	VACATION	отпуск	\N	2026-09-27 19:09:43.766361+07	4
11	absence	TRIP	командировк	\N	2026-09-27 19:09:43.766361+07	4
12	absence	TRIP	учеб	\N	2026-09-27 19:09:43.766361+07	4
13	absence	TRIP	на сборы	\N	2026-09-27 19:09:43.766361+07	4
14	absence	SICK	больнич	\N	2026-09-27 19:09:43.766361+07	4
15	absence	SICK	госпитал	\N	2026-09-27 19:09:43.766361+07	4
16	absence	SICK	на лечени	\N	2026-09-27 19:09:43.766361+07	4
17	absence	DAY_OFF	отгул	\N	2026-09-27 19:09:43.766361+07	4
18	mark_yes	\N	допущен	\N	2026-09-27 19:09:43.766361+07	5
19	mark_yes	\N	допущена	\N	2026-09-27 19:09:43.766361+07	5
20	mark_yes	\N	да	\N	2026-09-27 19:09:43.766361+07	5
21	mark_yes	\N	+	\N	2026-09-27 19:09:43.766361+07	5
22	mark_yes	\N	v	\N	2026-09-27 19:09:43.766361+07	5
23	mark_yes	\N	✓	\N	2026-09-27 19:09:43.766361+07	5
\.


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: parse; Owner: -
--

COPY parse.profiles (id, name, header_phrases, absence_code, permit_type_id, reserve_weapons, default_days, is_active, sort_order, created_by, created_at) FROM stdin;
\.


--
-- Data for Name: sections; Type: TABLE DATA; Schema: parse; Owner: -
--

COPY parse.sections (id, name, kind, builtin, sort_order, created_by, created_at) FROM stdin;
1	Заголовок: приказ о допуске	order_permit	t	10	\N	2026-09-27 19:25:49.079698+07
2	Заголовок: приказ об отсутствии	order_absence	t	20	\N	2026-09-27 19:25:49.079698+07
3	Вид допуска — иное написание	permit	t	30	\N	2026-09-27 19:25:49.079698+07
4	Причина отсутствия — иное написание	absence	t	40	\N	2026-09-27 19:25:49.079698+07
5	Отметка «допущен» в таблице	mark_yes	t	50	\N	2026-09-27 19:25:49.079698+07
\.


--
-- Data for Name: absence_types; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.absence_types (id, code, name, blocks_duty, sort_order) FROM stdin;
1	VACATION	Отпуск	t	10
2	SICK	Больничный	t	20
3	TRIP	Командировка / учеба	t	30
4	DAY_OFF	Отгул	t	40
5	OTHER	Прочее (привлечение по отдельному приказу)	t	50
\.


--
-- Data for Name: absences; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.absences (id, employee_id, absence_type_id, date_from, date_to, document_ref, note, created_at, updated_at, created_by, source, cancelled_at, cancelled_by, order_id) FROM stdin;
1	3	1	2026-08-14	2026-09-13	приказ на убытие № 101 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
2	14	1	2026-08-14	2026-09-13	приказ на убытие № 101 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
3	27	1	2026-08-14	2026-09-13	приказ на убытие № 101 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
4	8	2	2026-08-20	2026-08-30	справка (условная)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
5	22	2	2026-08-20	2026-08-30	справка (условная)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
6	5	3	2026-08-29	2026-09-08	приказ на убытие № 118 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
7	31	3	2026-08-29	2026-09-08	приказ на убытие № 118 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	manual	\N	\N	\N
8	142	5	2026-09-20	2026-09-22	приказ № 118 от 18.09.2026	временный караул	2026-09-07 15:15:55.617719+07	2026-09-07 15:15:55.617719+07	1	manual	\N	\N	\N
9	71	5	2026-09-08	2026-09-08	Приказ 118 от 08.09.2026	Караул	2026-09-07 15:25:08.480496+07	2026-09-07 15:25:08.480496+07	1	manual	\N	\N	\N
10	165	1	2026-09-21	2026-09-21	пр. 77 от 20.09.2026	\N	2026-09-20 14:26:58.788539+07	2026-09-20 14:26:58.818152+07	\N	manual	2026-09-20 14:26:58.816369+07	\N	\N
11	165	4	2026-09-21	2026-09-21	\N	\N	2026-09-20 14:40:24.087531+07	2026-09-20 15:09:53.4364+07	1	manual	2026-09-20 15:09:53.4364+07	1	\N
12	170	1	2026-09-30	2026-10-08	Приказ 	\N	2026-09-27 15:55:36.172506+07	2026-09-27 15:55:36.172506+07	1	manual	\N	\N	\N
\.


--
-- Data for Name: employee_permits; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.employee_permits (id, employee_id, permit_type_id, issued_at, expires_at, status, suspended_from, suspended_to, suspend_reason, document_ref, note, created_at, updated_at, post_id, order_id) FROM stdin;
1	1	5	2025-12-24	2026-12-24	suspended	2026-08-04	2026-10-03	приостановлен по результатам медицинского осмотра	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
1622	32	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1623	32	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1624	32	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1625	87	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1626	87	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1627	89	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1628	89	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1629	91	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
10	10	5	2025-12-24	2026-06-24	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
11	11	5	2025-12-24	2026-12-24	suspended	2026-08-04	2026-10-03	приостановлен по результатам медицинского осмотра	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
1630	91	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1631	79	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1632	79	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1633	81	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1634	81	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1635	83	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1636	83	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1637	85	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
20	20	5	2025-12-24	2026-06-24	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
21	21	5	2025-12-24	2026-12-24	suspended	2026-08-04	2026-10-03	приостановлен по результатам медицинского осмотра	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
1638	85	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1639	73	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1640	73	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1641	75	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1642	75	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1643	77	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1644	77	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1645	28	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
30	30	5	2025-12-24	2026-06-24	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
31	31	5	2025-12-24	2026-12-24	suspended	2026-08-04	2026-10-03	приостановлен по результатам медицинского осмотра	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
1646	40	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1647	71	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1648	71	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1649	55	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1650	55	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1651	57	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1652	57	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1653	57	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
40	40	5	2025-12-24	2026-06-24	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
41	1	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
42	3	6	2023-08-24	2026-07-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
43	4	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
44	5	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
45	6	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
46	7	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
47	8	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
48	9	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
49	10	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
50	11	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
51	13	6	2023-08-24	2026-07-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
52	14	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
53	15	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
54	16	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
55	17	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
56	18	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
57	19	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
58	20	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
59	21	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
60	23	6	2023-08-24	2026-07-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
61	24	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
62	25	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
1654	33	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1655	33	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1656	33	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1657	86	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1658	86	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1659	88	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1660	88	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1661	90	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1662	90	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1663	92	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1664	92	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1665	80	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1666	80	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1667	82	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1668	82	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1669	84	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
63	26	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
64	27	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
65	28	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
66	29	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
67	30	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
68	31	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
69	33	6	2023-08-24	2026-07-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
70	34	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
71	35	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
72	36	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
73	37	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
74	38	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
75	39	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
76	40	6	2023-08-24	2028-08-24	active	\N	\N	\N	приказ № 7 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
1670	84	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1671	29	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1672	29	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1673	72	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1674	72	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1675	74	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1676	74	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1677	76	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1678	76	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1679	78	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1680	78	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
655	44	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1681	70	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1682	70	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1683	54	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1684	56	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1685	56	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1686	56	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1687	91	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1688	91	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1689	91	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1690	79	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1691	79	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
667	50	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1692	79	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1693	81	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1694	81	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1695	81	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1696	83	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1697	83	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1698	83	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1699	85	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1700	85	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1701	85	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1702	73	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
679	56	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1703	73	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1704	73	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1705	75	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1706	75	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
684	59	5	2026-02-10	2027-02-10	suspended	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1707	75	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1708	77	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1709	77	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1710	77	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1711	4	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1712	16	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1713	28	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1714	28	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1715	40	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1716	40	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1717	40	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1718	71	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1719	71	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1720	71	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1721	55	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1722	55	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1723	57	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1724	57	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1725	59	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1726	59	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1727	61	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1728	61	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1729	63	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1730	63	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1731	65	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1732	65	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1733	67	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1734	67	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1735	69	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1736	69	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1737	41	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1738	43	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1739	43	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1740	45	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1741	45	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1742	47	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1743	47	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1744	49	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1745	49	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1746	51	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1747	51	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1748	53	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1749	53	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1750	90	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1751	90	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1752	90	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1753	92	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1754	92	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1755	92	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1756	80	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1757	80	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1758	80	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1759	82	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1760	82	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
691	62	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1761	82	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1762	84	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1763	84	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1764	84	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1765	5	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1766	17	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1767	29	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1768	29	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1769	29	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1770	72	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1771	72	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1772	72	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1773	74	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1774	74	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1775	74	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1776	76	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1777	76	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1778	76	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
703	68	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1779	78	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1780	78	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1781	78	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1782	70	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1783	70	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1784	70	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1785	54	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1786	54	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1787	56	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1788	56	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1789	58	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1790	58	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1791	60	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1792	60	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1793	62	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1794	62	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1795	64	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1796	64	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1797	66	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1798	66	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1799	68	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1800	68	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1801	42	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1802	42	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1803	44	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1804	44	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1805	46	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1806	46	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1807	48	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1808	48	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1809	50	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1810	50	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1811	52	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1812	52	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:46:58.341842+07	2026-09-19 14:46:58.341842+07	\N	\N
1813	61	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1814	67	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1815	25	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1816	43	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1817	37	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1818	51	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1819	65	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
715	74	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1820	52	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1821	69	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1822	88	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1823	66	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1824	50	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1825	63	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1826	24	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1827	87	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1828	12	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1829	42	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1830	86	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1831	59	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1832	62	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1833	41	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1834	48	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1835	64	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1836	68	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1837	86	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1838	47	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1839	12	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1840	42	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1841	87	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1842	59	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
725	79	6	2026-02-10	2027-02-10	suspended	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1843	44	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1844	62	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1845	41	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1846	53	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1847	48	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
727	80	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1848	64	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1849	36	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1850	46	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1851	49	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1852	13	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1853	67	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1854	89	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1855	25	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1856	58	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1857	1	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1858	51	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1859	88	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1860	69	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1861	60	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1862	66	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1863	50	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1864	45	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1865	67	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
739	86	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1866	61	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1867	49	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1868	13	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1869	43	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1870	1	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1871	58	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1872	69	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1873	52	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1874	65	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1875	51	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1876	37	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1877	50	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1878	45	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1879	66	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1880	86	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1881	60	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1882	47	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1883	24	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1884	63	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1885	59	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1886	42	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1887	12	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1888	53	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1889	41	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1890	44	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1891	46	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1892	68	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1893	36	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1894	89	14	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1895	64	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1896	88	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1897	47	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1898	24	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1899	63	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1900	53	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1901	89	8	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1902	62	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1903	44	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1904	46	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1905	68	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1906	36	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1907	48	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1908	61	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1909	49	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1910	13	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1911	43	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1912	1	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1913	58	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1914	25	23	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1915	52	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1916	65	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1917	37	17	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1918	45	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
751	92	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1919	87	18	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
1920	60	15	2025-01-15	2028-06-30	active	\N	\N	\N	\N	\N	2026-09-19 14:47:34.92622+07	2026-09-19 14:47:34.92622+07	\N	\N
763	98	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
766	100	5	2026-02-10	2027-02-10	suspended	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
775	104	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
787	110	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
343	35	16	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
1565	81	26	2025-01-15	2028-04-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1566	82	25	2025-01-15	2028-05-08	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1567	82	26	2025-01-15	2028-05-08	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1568	83	25	2025-01-15	2028-06-14	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1569	83	26	2025-01-15	2028-06-14	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1570	84	25	2025-01-15	2028-07-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1571	84	26	2025-01-15	2028-07-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1572	85	25	2025-01-15	2028-08-27	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1573	85	26	2025-01-15	2028-08-27	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1574	86	25	2025-01-15	2028-10-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1575	86	26	2025-01-15	2028-10-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1576	87	25	2025-01-15	2028-11-09	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1577	87	26	2025-01-15	2028-11-09	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1578	88	25	2025-01-15	2028-12-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1579	88	26	2025-01-15	2028-12-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
2	2	5	2025-12-24	2028-03-29	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
3	3	5	2025-12-24	2028-05-05	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
4	4	5	2025-12-24	2028-06-11	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
5	5	5	2025-12-24	2028-07-18	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
6	6	5	2025-12-24	2028-08-24	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
7	7	5	2025-12-24	2028-09-30	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
8	8	5	2025-12-24	2028-11-06	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
9	9	5	2025-12-24	2028-12-13	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
12	12	5	2025-12-24	2028-04-03	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
13	13	5	2025-12-24	2028-05-10	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
14	14	5	2025-12-24	2028-06-16	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
15	15	5	2025-12-24	2028-07-23	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
16	16	5	2025-12-24	2028-08-29	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
17	17	5	2025-12-24	2028-10-05	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
18	18	5	2025-12-24	2028-11-11	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
19	19	5	2025-12-24	2028-12-18	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
22	22	5	2025-12-24	2028-04-08	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
799	116	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
24	24	5	2025-12-24	2028-06-21	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
25	25	5	2025-12-24	2028-07-28	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
26	26	5	2025-12-24	2028-09-03	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
27	27	5	2025-12-24	2028-10-10	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
28	28	5	2025-12-24	2028-11-16	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
807	120	6	2026-02-10	2027-02-10	suspended	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
29	29	5	2025-12-24	2028-12-23	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
32	32	5	2025-12-24	2028-04-13	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
33	33	5	2025-12-24	2028-05-20	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
34	34	5	2025-12-24	2028-06-26	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
35	35	5	2025-12-24	2028-08-02	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
36	36	5	2025-12-24	2028-09-08	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
811	122	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
37	37	5	2025-12-24	2028-10-15	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
38	38	5	2025-12-24	2028-11-21	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
39	39	5	2025-12-24	2028-12-28	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
644	2	6	2026-02-10	2028-03-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
645	12	6	2026-02-10	2028-04-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
646	22	6	2026-02-10	2028-04-08	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
647	32	6	2026-02-10	2028-04-13	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
648	41	5	2026-02-10	2028-03-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
649	41	6	2026-02-10	2028-03-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
650	42	5	2026-02-10	2028-04-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
651	42	6	2026-02-10	2028-04-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
652	43	5	2026-02-10	2028-05-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
653	43	6	2026-02-10	2028-05-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
654	44	5	2026-02-10	2028-07-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
656	45	5	2026-02-10	2028-08-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
657	45	6	2026-02-10	2028-08-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
660	47	5	2026-02-10	2028-10-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
661	47	6	2026-02-10	2028-10-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
662	48	5	2026-02-10	2028-11-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
663	48	6	2026-02-10	2028-11-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
664	49	5	2026-02-10	2029-01-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
665	49	6	2026-02-10	2029-01-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
666	50	5	2026-02-10	2028-02-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
668	51	5	2026-02-10	2028-03-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
669	51	6	2026-02-10	2028-03-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
670	52	5	2026-02-10	2028-04-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
671	52	6	2026-02-10	2028-04-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
672	53	5	2026-02-10	2028-05-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
673	53	6	2026-02-10	2028-05-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
674	54	5	2026-02-10	2028-07-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
675	54	6	2026-02-10	2028-07-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
676	55	5	2026-02-10	2028-08-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
677	55	6	2026-02-10	2028-08-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
678	56	5	2026-02-10	2028-09-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
680	57	5	2026-02-10	2028-10-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
681	57	6	2026-02-10	2028-10-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
682	58	5	2026-02-10	2028-12-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
683	58	6	2026-02-10	2028-12-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
685	59	6	2026-02-10	2029-01-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
686	60	5	2026-02-10	2028-02-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
120	5	3	2026-04-24	2028-07-18	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
121	5	4	2026-04-24	2028-07-18	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
122	10	3	2026-04-24	2028-01-20	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
123	10	4	2026-04-24	2028-01-20	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
124	15	3	2026-04-24	2028-07-23	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
125	15	4	2026-04-24	2028-07-23	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
126	20	3	2026-04-24	2028-01-25	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
127	20	4	2026-04-24	2028-01-25	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
1422	1	25	2025-01-15	2028-02-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
128	25	3	2026-04-24	2028-07-28	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
129	25	4	2026-04-24	2028-07-28	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
130	30	3	2026-04-24	2028-01-30	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
131	30	4	2026-04-24	2028-01-30	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
132	35	3	2026-04-24	2028-08-02	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
133	35	4	2026-04-24	2028-08-02	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
134	40	3	2026-04-24	2028-02-04	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
135	40	4	2026-04-24	2028-02-04	active	\N	\N	\N	приказ № 45 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
687	60	6	2026-02-10	2028-02-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
688	61	5	2026-02-10	2028-03-22	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1423	1	26	2025-01-15	2028-02-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1424	2	25	2025-01-15	2028-03-29	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1425	2	26	2025-01-15	2028-03-29	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1426	3	25	2025-01-15	2028-05-05	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1427	3	26	2025-01-15	2028-05-05	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1428	4	25	2025-01-15	2028-06-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
689	61	6	2026-02-10	2028-03-22	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1429	4	26	2025-01-15	2028-06-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1430	5	25	2025-01-15	2028-07-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1431	5	26	2025-01-15	2028-07-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
690	62	5	2026-02-10	2028-04-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1432	6	25	2025-01-15	2028-08-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
692	63	5	2026-02-10	2028-06-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1433	6	26	2025-01-15	2028-08-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
693	63	6	2026-02-10	2028-06-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1434	7	25	2025-01-15	2028-09-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
694	64	5	2026-02-10	2028-07-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
695	64	6	2026-02-10	2028-07-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
696	65	5	2026-02-10	2028-08-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1435	7	26	2025-01-15	2028-09-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1436	8	25	2025-01-15	2028-11-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
697	65	6	2026-02-10	2028-08-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
698	66	5	2026-02-10	2028-09-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
699	66	6	2026-02-10	2028-09-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1437	8	26	2025-01-15	2028-11-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1438	12	25	2025-01-15	2028-04-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
700	67	5	2026-02-10	2028-10-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
701	67	6	2026-02-10	2028-10-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
702	68	5	2026-02-10	2028-12-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1439	12	26	2025-01-15	2028-04-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1440	13	25	2025-01-15	2028-05-10	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1441	13	26	2025-01-15	2028-05-10	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
706	70	5	2026-02-10	2028-02-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1442	14	25	2025-01-15	2028-06-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1443	14	26	2025-01-15	2028-06-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1444	15	25	2025-01-15	2028-07-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
707	70	6	2026-02-10	2028-02-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1445	15	26	2025-01-15	2028-07-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1446	16	25	2025-01-15	2028-08-29	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1447	16	26	2025-01-15	2028-08-29	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1448	17	25	2025-01-15	2028-10-05	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1449	17	26	2025-01-15	2028-10-05	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1450	18	25	2025-01-15	2028-11-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
708	71	5	2026-02-10	2028-03-27	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1451	18	26	2025-01-15	2028-11-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
709	71	6	2026-02-10	2028-03-27	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1452	19	25	2025-01-15	2028-12-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1453	19	26	2025-01-15	2028-12-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1454	20	25	2025-01-15	2028-01-25	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
710	72	5	2026-02-10	2028-05-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
711	72	6	2026-02-10	2028-05-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1455	20	26	2025-01-15	2028-01-25	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1456	24	25	2025-01-15	2028-06-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1457	24	26	2025-01-15	2028-06-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
138	1	19	2026-04-24	2028-02-21	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
1458	25	25	2025-01-15	2028-07-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1459	25	26	2025-01-15	2028-07-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1460	26	25	2025-01-15	2028-09-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1461	26	26	2025-01-15	2028-09-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1462	27	25	2025-01-15	2028-10-10	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1463	27	26	2025-01-15	2028-10-10	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1464	28	25	2025-01-15	2028-11-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1465	28	26	2025-01-15	2028-11-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1466	29	25	2025-01-15	2028-12-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1467	29	26	2025-01-15	2028-12-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1468	30	25	2025-01-15	2028-01-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1469	30	26	2025-01-15	2028-01-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1470	31	25	2025-01-15	2028-03-07	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
712	73	5	2026-02-10	2028-06-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
823	128	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
1471	31	26	2025-01-15	2028-03-07	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
713	73	6	2026-02-10	2028-06-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1472	32	25	2025-01-15	2028-04-13	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
714	74	5	2026-02-10	2028-07-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1473	32	26	2025-01-15	2028-04-13	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1474	36	25	2025-01-15	2028-09-08	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1475	36	26	2025-01-15	2028-09-08	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
716	75	5	2026-02-10	2028-08-22	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
717	75	6	2026-02-10	2028-08-22	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
718	76	5	2026-02-10	2028-09-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
719	76	6	2026-02-10	2028-09-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1476	37	25	2025-01-15	2028-10-15	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
720	77	5	2026-02-10	2028-11-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1477	37	26	2025-01-15	2028-10-15	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1478	38	25	2025-01-15	2028-11-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
721	77	6	2026-02-10	2028-11-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
722	78	5	2026-02-10	2028-12-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1479	38	26	2025-01-15	2028-11-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
723	78	6	2026-02-10	2028-12-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1480	39	25	2025-01-15	2028-12-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
724	79	5	2026-02-10	2028-01-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1481	39	26	2025-01-15	2028-12-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1482	40	25	2025-01-15	2028-02-04	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1483	40	26	2025-01-15	2028-02-04	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1484	41	25	2025-01-15	2028-03-12	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1485	41	26	2025-01-15	2028-03-12	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1486	42	25	2025-01-15	2028-04-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1487	42	26	2025-01-15	2028-04-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
726	80	5	2026-02-10	2028-02-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1488	43	25	2025-01-15	2028-05-25	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1489	43	26	2025-01-15	2028-05-25	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1490	44	25	2025-01-15	2028-07-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1491	44	26	2025-01-15	2028-07-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1492	45	25	2025-01-15	2028-08-07	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
728	81	5	2026-02-10	2028-04-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1493	45	26	2025-01-15	2028-08-07	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
729	81	6	2026-02-10	2028-04-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
730	82	5	2026-02-10	2028-05-08	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
731	82	6	2026-02-10	2028-05-08	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
732	83	5	2026-02-10	2028-06-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
733	83	6	2026-02-10	2028-06-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
734	84	5	2026-02-10	2028-07-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
735	84	6	2026-02-10	2028-07-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
736	85	5	2026-02-10	2028-08-27	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1496	47	25	2025-01-15	2028-10-20	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
737	85	6	2026-02-10	2028-08-27	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1497	47	26	2025-01-15	2028-10-20	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1498	48	25	2025-01-15	2028-11-26	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
835	134	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
847	140	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
848	141	5	2026-02-10	2026-09-25	suspended	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
859	146	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
871	152	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
883	158	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
889	161	6	2026-02-10	2027-02-10	suspended	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
895	164	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
907	170	6	2026-02-10	2026-08-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-07 14:42:17.371118+07	\N	8
738	86	5	2026-02-10	2028-10-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
740	87	5	2026-02-10	2028-11-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1499	48	26	2025-01-15	2028-11-26	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
741	87	6	2026-02-10	2028-11-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
202	20	20	2026-04-24	2028-01-25	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
204	20	21	2026-04-24	2028-01-25	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
206	21	22	2026-04-24	2028-03-02	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
1500	49	25	2025-01-15	2029-01-02	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1501	49	26	2025-01-15	2029-01-02	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1502	50	25	2025-01-15	2028-02-09	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1503	50	26	2025-01-15	2028-02-09	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1504	51	25	2025-01-15	2028-03-17	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1505	51	26	2025-01-15	2028-03-17	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1506	52	25	2025-01-15	2028-04-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1507	52	26	2025-01-15	2028-04-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1508	53	25	2025-01-15	2028-05-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1509	53	26	2025-01-15	2028-05-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1510	54	25	2025-01-15	2028-07-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1511	54	26	2025-01-15	2028-07-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1512	55	25	2025-01-15	2028-08-12	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1513	55	26	2025-01-15	2028-08-12	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1514	56	25	2025-01-15	2028-09-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1515	56	26	2025-01-15	2028-09-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1516	57	25	2025-01-15	2028-10-25	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1517	57	26	2025-01-15	2028-10-25	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1518	58	25	2025-01-15	2028-12-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1519	58	26	2025-01-15	2028-12-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
742	88	5	2026-02-10	2028-12-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1520	59	25	2025-01-15	2029-01-07	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1521	59	26	2025-01-15	2029-01-07	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
743	88	6	2026-02-10	2028-12-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
744	89	5	2026-02-10	2028-01-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
745	89	6	2026-02-10	2028-01-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1522	60	25	2025-01-15	2028-02-14	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
746	90	5	2026-02-10	2028-02-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
747	90	6	2026-02-10	2028-02-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
748	91	5	2026-02-10	2028-04-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1523	60	26	2025-01-15	2028-02-14	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
749	91	6	2026-02-10	2028-04-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1524	61	25	2025-01-15	2028-03-22	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
752	93	5	2026-02-10	2028-06-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
753	93	6	2026-02-10	2028-06-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
754	94	5	2026-02-10	2028-07-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
755	94	6	2026-02-10	2028-07-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1525	61	26	2025-01-15	2028-03-22	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
756	95	5	2026-02-10	2028-09-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
757	95	6	2026-02-10	2028-09-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
758	96	5	2026-02-10	2028-10-08	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
759	96	6	2026-02-10	2028-10-08	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
760	97	5	2026-02-10	2028-11-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
761	97	6	2026-02-10	2028-11-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
762	98	5	2026-02-10	2028-12-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
764	99	5	2026-02-10	2028-01-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
765	99	6	2026-02-10	2028-01-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
767	100	6	2026-02-10	2028-03-05	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
768	101	5	2026-02-10	2028-04-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
769	101	6	2026-02-10	2028-04-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1526	62	25	2025-01-15	2028-04-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1527	62	26	2025-01-15	2028-04-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1528	63	25	2025-01-15	2028-06-04	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1529	63	26	2025-01-15	2028-06-04	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1530	64	25	2025-01-15	2028-07-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
770	102	5	2026-02-10	2028-05-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1531	64	26	2025-01-15	2028-07-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1532	65	25	2025-01-15	2028-08-17	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1533	65	26	2025-01-15	2028-08-17	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1534	66	25	2025-01-15	2028-09-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
771	102	6	2026-02-10	2028-05-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
772	103	5	2026-02-10	2028-06-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
773	103	6	2026-02-10	2028-06-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1535	66	26	2025-01-15	2028-09-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1536	67	25	2025-01-15	2028-10-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1537	67	26	2025-01-15	2028-10-30	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1538	68	25	2025-01-15	2028-12-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1539	68	26	2025-01-15	2028-12-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1542	70	25	2025-01-15	2028-02-19	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1543	70	26	2025-01-15	2028-02-19	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
774	104	5	2026-02-10	2028-07-31	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1544	71	25	2025-01-15	2028-03-27	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1545	71	26	2025-01-15	2028-03-27	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1546	72	25	2025-01-15	2028-05-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1547	72	26	2025-01-15	2028-05-03	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1548	73	25	2025-01-15	2028-06-09	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1549	73	26	2025-01-15	2028-06-09	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1550	74	25	2025-01-15	2028-07-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1551	74	26	2025-01-15	2028-07-16	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1552	75	25	2025-01-15	2028-08-22	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1553	75	26	2025-01-15	2028-08-22	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1554	76	25	2025-01-15	2028-09-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1555	76	26	2025-01-15	2028-09-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1556	77	25	2025-01-15	2028-11-04	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1557	77	26	2025-01-15	2028-11-04	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1558	78	25	2025-01-15	2028-12-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1559	78	26	2025-01-15	2028-12-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1560	79	25	2025-01-15	2028-01-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1561	79	26	2025-01-15	2028-01-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1562	80	25	2025-01-15	2028-02-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1563	80	26	2025-01-15	2028-02-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1564	81	25	2025-01-15	2028-04-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1580	89	25	2025-01-15	2028-01-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1581	89	26	2025-01-15	2028-01-23	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1582	90	25	2025-01-15	2028-02-29	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
776	105	5	2026-02-10	2028-09-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
777	105	6	2026-02-10	2028-09-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
778	106	5	2026-02-10	2028-10-13	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
779	106	6	2026-02-10	2028-10-13	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
780	107	5	2026-02-10	2028-11-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1583	90	26	2025-01-15	2028-02-29	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1584	91	25	2025-01-15	2028-04-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1585	91	26	2025-01-15	2028-04-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
781	107	6	2026-02-10	2028-11-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
782	108	5	2026-02-10	2028-12-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
783	108	6	2026-02-10	2028-12-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
784	109	5	2026-02-10	2028-02-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1588	93	25	2025-01-15	2028-06-19	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1589	93	26	2025-01-15	2028-06-19	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1590	94	25	2025-01-15	2028-07-26	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
785	109	6	2026-02-10	2028-02-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
786	110	5	2026-02-10	2028-03-10	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1591	94	26	2025-01-15	2028-07-26	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1592	95	25	2025-01-15	2028-09-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1593	95	26	2025-01-15	2028-09-01	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1594	96	25	2025-01-15	2028-10-08	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1595	96	26	2025-01-15	2028-10-08	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1596	97	25	2025-01-15	2028-11-14	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1597	97	26	2025-01-15	2028-11-14	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1598	98	25	2025-01-15	2028-12-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1599	98	26	2025-01-15	2028-12-21	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1600	99	25	2025-01-15	2028-01-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
788	111	5	2026-02-10	2028-04-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
789	111	6	2026-02-10	2028-04-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1601	99	26	2025-01-15	2028-01-28	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1602	100	25	2025-01-15	2028-03-05	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1603	100	26	2025-01-15	2028-03-05	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1604	101	25	2025-01-15	2028-04-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1605	101	26	2025-01-15	2028-04-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1606	102	25	2025-01-15	2028-05-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1607	102	26	2025-01-15	2028-05-18	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1608	103	25	2025-01-15	2028-06-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1609	103	26	2025-01-15	2028-06-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1610	104	25	2025-01-15	2028-07-31	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1611	104	26	2025-01-15	2028-07-31	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1612	105	25	2025-01-15	2028-09-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1613	105	26	2025-01-15	2028-09-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1614	106	25	2025-01-15	2028-10-13	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1615	106	26	2025-01-15	2028-10-13	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
342	34	16	2026-03-05	2028-06-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
344	110	16	2026-03-05	2028-03-10	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
1616	107	25	2025-01-15	2028-11-19	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1617	107	26	2025-01-15	2028-11-19	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1618	108	25	2025-01-15	2028-12-26	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1619	108	26	2025-01-15	2028-12-26	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1620	109	25	2025-01-15	2028-02-02	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1621	109	26	2025-01-15	2028-02-02	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
790	112	5	2026-02-10	2028-05-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
791	112	6	2026-02-10	2028-05-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
792	113	5	2026-02-10	2028-06-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
793	113	6	2026-02-10	2028-06-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
794	114	5	2026-02-10	2028-08-05	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
795	114	6	2026-02-10	2028-08-05	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
798	116	5	2026-02-10	2028-10-18	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
800	117	5	2026-02-10	2028-11-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
801	117	6	2026-02-10	2028-11-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
802	118	5	2026-02-10	2028-12-31	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
803	118	6	2026-02-10	2028-12-31	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
804	119	5	2026-02-10	2028-02-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
805	119	6	2026-02-10	2028-02-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
806	120	5	2026-02-10	2028-03-15	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
808	121	5	2026-02-10	2028-04-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
809	121	6	2026-02-10	2028-04-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
810	122	5	2026-02-10	2028-05-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
812	123	5	2026-02-10	2028-07-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
813	123	6	2026-02-10	2028-07-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
814	124	5	2026-02-10	2028-08-10	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
815	124	6	2026-02-10	2028-08-10	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
816	125	5	2026-02-10	2028-09-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
817	125	6	2026-02-10	2028-09-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
818	126	5	2026-02-10	2028-10-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
407	94	10	2026-03-05	2028-07-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
408	8	9	2026-03-05	2028-11-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
819	126	6	2026-02-10	2028-10-23	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
820	127	5	2026-02-10	2028-11-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
821	127	6	2026-02-10	2028-11-29	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
822	128	5	2026-02-10	2029-01-05	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
824	129	5	2026-02-10	2028-02-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
825	129	6	2026-02-10	2028-02-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
537	57	18	2026-03-05	2028-10-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
538	59	18	2026-03-05	2029-01-07	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
539	61	18	2026-03-05	2028-03-22	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
540	9	12	2026-03-05	2028-12-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
826	130	5	2026-02-10	2028-03-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
827	130	6	2026-02-10	2028-03-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
828	131	5	2026-02-10	2028-04-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
829	131	6	2026-02-10	2028-04-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
830	132	5	2026-02-10	2028-06-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
831	132	6	2026-02-10	2028-06-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
832	133	5	2026-02-10	2028-07-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
833	133	6	2026-02-10	2028-07-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
834	134	5	2026-02-10	2028-08-15	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
836	135	5	2026-02-10	2028-09-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
837	135	6	2026-02-10	2028-09-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
838	136	5	2026-02-10	2028-10-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
839	136	6	2026-02-10	2028-10-28	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
840	137	5	2026-02-10	2028-12-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
841	137	6	2026-02-10	2028-12-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
844	139	5	2026-02-10	2028-02-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
845	139	6	2026-02-10	2028-02-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
846	140	5	2026-02-10	2028-03-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
849	141	6	2026-02-10	2028-05-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
850	142	5	2026-02-10	2028-06-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
851	142	6	2026-02-10	2028-06-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
852	143	5	2026-02-10	2028-07-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
853	143	6	2026-02-10	2028-07-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
854	144	5	2026-02-10	2028-08-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
855	144	6	2026-02-10	2028-08-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
856	145	5	2026-02-10	2028-09-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
857	145	6	2026-02-10	2028-09-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
602	4	19	2026-03-05	2028-06-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
603	5	19	2026-03-05	2028-07-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
604	7	19	2026-03-05	2028-09-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
608	14	19	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
609	15	19	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
610	17	19	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
611	18	19	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
612	2	19	2026-03-05	2028-03-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
858	146	5	2026-02-10	2028-11-02	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
860	147	5	2026-02-10	2028-12-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
861	147	6	2026-02-10	2028-12-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
862	148	5	2026-02-10	2028-01-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
863	148	6	2026-02-10	2028-01-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
864	149	5	2026-02-10	2028-02-22	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
865	149	6	2026-02-10	2028-02-22	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
866	150	5	2026-02-10	2028-03-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
867	150	6	2026-02-10	2028-03-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
868	151	5	2026-02-10	2028-05-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
869	151	6	2026-02-10	2028-05-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
870	152	5	2026-02-10	2028-06-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
872	153	5	2026-02-10	2028-07-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
873	153	6	2026-02-10	2028-07-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
874	154	5	2026-02-10	2028-08-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
875	154	6	2026-02-10	2028-08-25	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
876	155	5	2026-02-10	2028-10-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
877	155	6	2026-02-10	2028-10-01	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
878	156	5	2026-02-10	2028-11-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
879	156	6	2026-02-10	2028-11-07	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
880	157	5	2026-02-10	2028-12-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
881	157	6	2026-02-10	2028-12-14	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
882	158	5	2026-02-10	2028-01-21	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
884	159	5	2026-02-10	2028-02-27	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
885	159	6	2026-02-10	2028-02-27	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
886	160	5	2026-02-10	2028-04-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
887	160	6	2026-02-10	2028-04-04	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
890	162	5	2026-02-10	2028-06-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
891	162	6	2026-02-10	2028-06-17	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
892	163	5	2026-02-10	2028-07-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
893	163	6	2026-02-10	2028-07-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
894	164	5	2026-02-10	2028-08-30	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
896	165	5	2026-02-10	2028-10-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
897	165	6	2026-02-10	2028-10-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
898	166	5	2026-02-10	2028-11-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
899	166	6	2026-02-10	2028-11-12	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
900	167	5	2026-02-10	2028-12-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
901	167	6	2026-02-10	2028-12-19	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
902	168	5	2026-02-10	2028-01-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
903	168	6	2026-02-10	2028-01-26	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
904	169	5	2026-02-10	2028-03-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
905	169	6	2026-02-10	2028-03-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
906	170	5	2026-02-10	2028-04-09	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
184	15	23	2026-04-24	2028-07-23	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
186	15	19	2026-04-24	2028-07-23	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
188	16	15	2026-04-24	2028-08-29	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
189	16	17	2026-04-24	2028-08-29	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
190	16	19	2026-04-24	2028-08-29	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
193	17	8	2026-04-24	2028-10-05	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
194	17	19	2026-04-24	2028-10-05	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
195	18	11	2026-04-24	2028-11-11	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
198	18	19	2026-04-24	2028-11-11	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
201	19	19	2026-04-24	2028-12-18	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
208	21	12	2026-04-24	2028-03-02	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
210	22	16	2026-04-24	2028-04-08	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
211	22	10	2026-04-24	2028-04-08	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
218	24	18	2026-04-24	2028-06-21	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
219	24	19	2026-04-24	2028-06-21	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
222	25	18	2026-04-24	2028-07-28	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
224	25	19	2026-04-24	2028-07-28	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
226	26	15	2026-04-24	2028-09-03	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
227	26	19	2026-04-24	2028-09-03	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
228	27	8	2026-04-24	2028-10-10	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
229	27	19	2026-04-24	2028-10-10	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
230	28	11	2026-04-24	2028-11-16	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
231	28	14	2026-04-24	2028-11-16	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
232	28	19	2026-04-24	2028-11-16	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
235	29	17	2026-04-24	2028-12-23	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
236	29	19	2026-04-24	2028-12-23	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
237	30	20	2026-04-24	2028-01-30	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
238	30	23	2026-04-24	2028-01-30	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
240	30	19	2026-04-24	2028-01-30	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
242	31	15	2026-04-24	2028-03-07	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
244	31	19	2026-04-24	2028-03-07	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
246	32	10	2026-04-24	2028-04-13	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
253	33	13	2026-04-24	2028-05-20	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
255	34	24	2026-04-24	2028-06-26	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
265	36	19	2026-04-24	2028-09-08	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
266	37	8	2026-04-24	2028-10-15	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
267	37	19	2026-04-24	2028-10-15	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
268	38	11	2026-04-24	2028-11-21	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
269	38	14	2026-04-24	2028-11-21	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
270	38	19	2026-04-24	2028-11-21	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
271	39	19	2026-04-24	2028-12-28	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
272	40	20	2026-04-24	2028-02-04	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
273	40	23	2026-04-24	2028-02-04	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
275	40	19	2026-04-24	2028-02-04	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
277	5	17	2026-08-20	2028-07-18	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
279	17	17	2026-08-20	2028-10-05	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
280	4	17	2026-08-20	2028-06-11	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
284	1	18	2026-08-20	2028-02-21	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
288	1	18	2026-08-20	2028-02-21	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
290	13	18	2026-08-20	2028-05-10	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
297	12	18	2026-08-20	2028-04-03	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
312	2	15	2026-08-20	2028-03-29	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
313	3	15	2026-08-20	2028-05-05	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
314	4	15	2026-08-20	2028-06-11	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
315	5	15	2026-08-20	2028-07-18	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
316	7	15	2026-08-20	2028-09-30	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
318	1	14	2026-08-20	2028-02-21	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
319	2	14	2026-08-20	2028-03-29	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
320	4	14	2026-08-20	2028-06-11	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
321	5	14	2026-08-20	2028-07-18	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
325	2	23	2026-08-20	2028-03-29	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
326	3	23	2026-08-20	2028-05-05	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
327	4	23	2026-08-20	2028-06-11	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
328	6	23	2026-08-20	2028-08-24	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
329	7	23	2026-08-20	2028-09-30	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
330	1	8	2026-08-20	2028-02-21	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
331	3	8	2026-08-20	2028-05-05	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
332	4	8	2026-08-20	2028-06-11	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
333	5	8	2026-08-20	2028-07-18	active	\N	\N	\N	приказ № 54 от 20.08.2026	\N	2026-09-07 14:16:51.353616+07	2026-09-13 11:12:17.830107+07	\N	4
336	9	16	2026-03-05	2028-12-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
337	10	16	2026-03-05	2028-01-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
338	11	16	2026-03-05	2028-02-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
339	21	16	2026-03-05	2028-03-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
341	33	16	2026-03-05	2028-05-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
345	111	16	2026-03-05	2028-04-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
346	112	16	2026-03-05	2028-05-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
347	113	16	2026-03-05	2028-06-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
348	10	24	2026-03-05	2028-01-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
350	21	24	2026-03-05	2028-03-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
351	22	24	2026-03-05	2028-04-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
353	33	24	2026-03-05	2028-05-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
356	111	24	2026-03-05	2028-04-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
357	112	24	2026-03-05	2028-05-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
358	113	24	2026-03-05	2028-06-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
359	114	24	2026-03-05	2028-08-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
365	8	22	2026-03-05	2028-11-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
366	9	22	2026-03-05	2028-12-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
372	2	11	2026-03-05	2028-03-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
373	4	11	2026-03-05	2028-06-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
374	5	11	2026-03-05	2028-07-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
375	6	11	2026-03-05	2028-08-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
376	7	11	2026-03-05	2028-09-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
380	14	11	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
381	15	11	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
382	16	11	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
383	17	11	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
384	2	20	2026-03-05	2028-03-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
385	3	20	2026-03-05	2028-05-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
386	4	20	2026-03-05	2028-06-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
387	6	20	2026-03-05	2028-08-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
388	7	20	2026-03-05	2028-09-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
389	8	20	2026-03-05	2028-11-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
392	14	20	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
393	16	20	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
394	17	20	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
395	18	20	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
396	8	10	2026-03-05	2028-11-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
397	9	10	2026-03-05	2028-12-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
398	10	10	2026-03-05	2028-01-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
399	11	10	2026-03-05	2028-02-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
400	20	10	2026-03-05	2028-01-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
401	21	10	2026-03-05	2028-03-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
404	34	10	2026-03-05	2028-06-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
405	35	10	2026-03-05	2028-08-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
406	93	10	2026-03-05	2028-06-19	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
411	20	9	2026-03-05	2028-01-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
412	21	9	2026-03-05	2028-03-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
416	33	9	2026-03-05	2028-05-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
418	93	9	2026-03-05	2028-06-19	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
419	94	9	2026-03-05	2028-07-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
422	14	15	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
423	15	15	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
424	17	15	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
425	18	15	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
426	19	15	2026-03-05	2028-12-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
430	27	15	2026-03-05	2028-10-10	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
431	28	15	2026-03-05	2028-11-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
435	14	14	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
436	15	14	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
437	16	14	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
438	17	14	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
443	26	14	2026-03-05	2028-09-03	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
447	14	23	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
448	16	23	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
449	17	23	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
450	18	23	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
455	26	23	2026-03-05	2028-09-03	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
459	14	8	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
460	15	8	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
461	16	8	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
467	26	8	2026-03-05	2028-09-03	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
468	70	17	2026-03-05	2028-02-19	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
469	72	17	2026-03-05	2028-05-03	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
470	74	17	2026-03-05	2028-07-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
471	76	17	2026-03-05	2028-09-28	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
472	78	17	2026-03-05	2028-12-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
473	80	17	2026-03-05	2028-02-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
474	82	17	2026-03-05	2028-05-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
476	86	17	2026-03-05	2028-10-03	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
477	88	17	2026-03-05	2028-12-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
478	90	17	2026-03-05	2028-02-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
480	28	17	2026-03-05	2028-11-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
481	40	17	2026-03-05	2028-02-04	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
482	71	17	2026-03-05	2028-03-27	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
483	73	17	2026-03-05	2028-06-09	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
484	75	17	2026-03-05	2028-08-22	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
485	77	17	2026-03-05	2028-11-04	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
486	79	17	2026-03-05	2028-01-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
488	83	17	2026-03-05	2028-06-14	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
489	85	17	2026-03-05	2028-08-27	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
490	87	17	2026-03-05	2028-11-09	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
491	89	17	2026-03-05	2028-01-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
492	25	18	2026-03-05	2028-07-28	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
493	37	18	2026-03-05	2028-10-15	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
494	42	18	2026-03-05	2028-04-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
495	44	18	2026-03-05	2028-07-01	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
497	48	18	2026-03-05	2028-11-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
498	50	18	2026-03-05	2028-02-09	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
500	54	18	2026-03-05	2028-07-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
501	56	18	2026-03-05	2028-09-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
502	58	18	2026-03-05	2028-12-01	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
503	60	18	2026-03-05	2028-02-14	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
504	37	18	2026-03-05	2028-10-15	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
505	42	18	2026-03-05	2028-04-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
506	44	18	2026-03-05	2028-07-01	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
508	48	18	2026-03-05	2028-11-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
509	50	18	2026-03-05	2028-02-09	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
510	52	18	2026-03-05	2028-04-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
512	56	18	2026-03-05	2028-09-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
513	58	18	2026-03-05	2028-12-01	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
514	60	18	2026-03-05	2028-02-14	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
515	62	18	2026-03-05	2028-04-28	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
516	24	18	2026-03-05	2028-06-21	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
517	36	18	2026-03-05	2028-09-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
518	41	18	2026-03-05	2028-03-12	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
519	43	18	2026-03-05	2028-05-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
520	45	18	2026-03-05	2028-08-07	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
521	47	18	2026-03-05	2028-10-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
522	49	18	2026-03-05	2029-01-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
524	53	18	2026-03-05	2028-05-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
525	55	18	2026-03-05	2028-08-12	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
526	57	18	2026-03-05	2028-10-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
527	59	18	2026-03-05	2029-01-07	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
528	36	18	2026-03-05	2028-09-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
529	41	18	2026-03-05	2028-03-12	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
530	43	18	2026-03-05	2028-05-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
531	45	18	2026-03-05	2028-08-07	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
532	47	18	2026-03-05	2028-10-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
533	49	18	2026-03-05	2029-01-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
534	51	18	2026-03-05	2028-03-17	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
536	55	18	2026-03-05	2028-08-12	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
541	10	12	2026-03-05	2028-01-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
542	22	12	2026-03-05	2028-04-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
544	33	12	2026-03-05	2028-05-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
545	34	12	2026-03-05	2028-06-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
546	35	12	2026-03-05	2028-08-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
548	111	12	2026-03-05	2028-04-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
549	112	12	2026-03-05	2028-05-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
550	113	12	2026-03-05	2028-06-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
551	114	12	2026-03-05	2028-08-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
552	9	13	2026-03-05	2028-12-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
553	10	13	2026-03-05	2028-01-20	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
555	21	13	2026-03-05	2028-03-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
556	22	13	2026-03-05	2028-04-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
557	34	13	2026-03-05	2028-06-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
560	111	13	2026-03-05	2028-04-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
561	112	13	2026-03-05	2028-05-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
562	113	13	2026-03-05	2028-06-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
563	114	13	2026-03-05	2028-08-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
564	8	21	2026-03-05	2028-11-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
565	9	21	2026-03-05	2028-12-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
567	21	21	2026-03-05	2028-03-02	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
568	22	21	2026-03-05	2028-04-08	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
570	32	21	2026-03-05	2028-04-13	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
572	34	21	2026-03-05	2028-06-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
573	93	21	2026-03-05	2028-06-19	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
574	94	21	2026-03-05	2028-07-26	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
575	95	21	2026-03-05	2028-09-01	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
576	3	19	2026-03-05	2028-05-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
577	4	19	2026-03-05	2028-06-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
578	5	19	2026-03-05	2028-07-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
579	6	19	2026-03-05	2028-08-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
584	14	19	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
585	15	19	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
586	16	19	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
587	18	19	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
588	2	19	2026-03-05	2028-03-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
589	3	19	2026-03-05	2028-05-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
590	5	19	2026-03-05	2028-07-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
591	6	19	2026-03-05	2028-08-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
592	7	19	2026-03-05	2028-09-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
596	15	19	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
597	16	19	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
139	2	8	2026-04-24	2028-03-29	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
140	2	19	2026-04-24	2028-03-29	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
141	3	11	2026-04-24	2028-05-05	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
142	3	14	2026-04-24	2028-05-05	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
143	3	19	2026-04-24	2028-05-05	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
145	4	19	2026-04-24	2028-06-11	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
146	5	20	2026-04-24	2028-07-18	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
147	5	23	2026-04-24	2028-07-18	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
150	5	19	2026-04-24	2028-07-18	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
152	6	15	2026-04-24	2028-08-24	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
154	6	19	2026-04-24	2028-08-24	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
158	7	19	2026-04-24	2028-09-30	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
159	8	11	2026-04-24	2028-11-06	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
163	9	24	2026-04-24	2028-12-13	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
164	9	9	2026-04-24	2028-12-13	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
169	10	21	2026-04-24	2028-01-20	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
173	11	12	2026-04-24	2028-02-26	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
175	12	8	2026-04-24	2028-04-03	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
176	12	18	2026-04-24	2028-04-03	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
177	12	19	2026-04-24	2028-04-03	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
179	13	14	2026-04-24	2028-05-10	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
180	13	18	2026-04-24	2028-05-10	active	\N	\N	\N	приказ № 51	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	1
181	13	19	2026-04-24	2028-05-10	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
182	14	19	2026-04-24	2028-06-16	active	\N	\N	\N	приказ № 53	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	3
183	15	20	2026-04-24	2028-07-23	active	\N	\N	\N	приказ № 52	\N	2026-08-24 15:32:26.129808+07	2026-09-13 11:12:17.830107+07	\N	2
598	17	19	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
599	18	19	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
600	2	19	2026-03-05	2028-03-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
601	3	19	2026-03-05	2028-05-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
613	4	19	2026-03-05	2028-06-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
614	5	19	2026-03-05	2028-07-18	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
615	6	19	2026-03-05	2028-08-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
616	7	19	2026-03-05	2028-09-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
620	14	19	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
621	15	19	2026-03-05	2028-07-23	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
622	16	19	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
623	17	19	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
624	2	19	2026-03-05	2028-03-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
625	3	19	2026-03-05	2028-05-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
626	4	19	2026-03-05	2028-06-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
627	6	19	2026-03-05	2028-08-24	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
628	7	19	2026-03-05	2028-09-30	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
632	14	19	2026-03-05	2028-06-16	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
633	16	19	2026-03-05	2028-08-29	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
634	17	19	2026-03-05	2028-10-05	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
635	18	19	2026-03-05	2028-11-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
908	114	16	2026-04-15	2028-08-05	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
355	110	24	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
367	10	22	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
403	33	10	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
415	32	9	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
451	19	23	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
475	84	17	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
487	81	17	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
499	52	18	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
511	54	18	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
523	51	18	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
535	53	18	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
547	110	12	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
559	110	13	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
571	33	21	2026-03-05	2026-08-25	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-11 23:31:51.758064+07	\N	6
910	116	16	2026-04-15	2028-10-18	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
911	117	16	2026-04-15	2028-11-24	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
912	118	16	2026-04-15	2028-12-31	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
914	116	24	2026-04-15	2028-10-18	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
915	117	24	2026-04-15	2028-11-24	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
916	118	24	2026-04-15	2028-12-31	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
917	20	22	2026-04-15	2028-01-25	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
918	32	22	2026-04-15	2028-04-13	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
919	93	22	2026-04-15	2028-06-19	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
920	94	22	2026-04-15	2028-07-26	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
921	95	22	2026-04-15	2028-09-01	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
922	96	22	2026-04-15	2028-10-08	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
923	26	11	2026-04-15	2028-09-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
924	54	11	2026-04-15	2028-07-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
925	55	11	2026-04-15	2028-08-12	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
926	56	11	2026-04-15	2028-09-18	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
927	26	20	2026-04-15	2028-09-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
928	38	20	2026-04-15	2028-11-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
929	54	20	2026-04-15	2028-07-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
930	95	10	2026-04-15	2028-09-01	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
931	96	10	2026-04-15	2028-10-08	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
932	97	10	2026-04-15	2028-11-14	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
933	98	10	2026-04-15	2028-12-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
934	95	9	2026-04-15	2028-09-01	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
935	96	9	2026-04-15	2028-10-08	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
936	97	9	2026-04-15	2028-11-14	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
937	98	9	2026-04-15	2028-12-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
938	99	9	2026-04-15	2028-01-28	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
939	100	9	2026-04-15	2028-03-05	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
940	38	15	2026-04-15	2028-11-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
941	54	15	2026-04-15	2028-07-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
942	12	14	2026-04-15	2028-04-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
943	24	14	2026-04-15	2028-06-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
944	25	14	2026-04-15	2028-07-28	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
945	36	14	2026-04-15	2028-09-08	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
946	37	14	2026-04-15	2028-10-15	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
947	38	23	2026-04-15	2028-11-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
948	54	23	2026-04-15	2028-07-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
949	55	23	2026-04-15	2028-08-12	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
950	13	8	2026-04-15	2028-05-10	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
951	24	8	2026-04-15	2028-06-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
952	25	8	2026-04-15	2028-07-28	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
953	36	8	2026-04-15	2028-09-08	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
954	41	8	2026-04-15	2028-03-12	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
955	91	17	2026-04-15	2028-04-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
956	62	18	2026-04-15	2028-04-28	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
957	64	18	2026-04-15	2028-07-11	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
958	66	18	2026-04-15	2028-09-23	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
959	68	18	2026-04-15	2028-12-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
960	64	18	2026-04-15	2028-07-11	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
961	66	18	2026-04-15	2028-09-23	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
962	68	18	2026-04-15	2028-12-06	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
963	61	18	2026-04-15	2028-03-22	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
964	63	18	2026-04-15	2028-06-04	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
965	65	18	2026-04-15	2028-08-17	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
966	67	18	2026-04-15	2028-10-30	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
968	63	18	2026-04-15	2028-06-04	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
969	65	18	2026-04-15	2028-08-17	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
970	67	18	2026-04-15	2028-10-30	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
973	116	12	2026-04-15	2028-10-18	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
974	117	12	2026-04-15	2028-11-24	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
975	118	12	2026-04-15	2028-12-31	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
977	116	13	2026-04-15	2028-10-18	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
978	117	13	2026-04-15	2028-11-24	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
979	118	13	2026-04-15	2028-12-31	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
980	96	21	2026-04-15	2028-10-08	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
981	97	21	2026-04-15	2028-11-14	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
982	98	21	2026-04-15	2028-12-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
983	1	19	2026-04-15	2028-02-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
984	13	19	2026-04-15	2028-05-10	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
985	24	19	2026-04-15	2028-06-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
986	25	19	2026-04-15	2028-07-28	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
987	1	19	2026-04-15	2028-02-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
988	12	19	2026-04-15	2028-04-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
989	13	19	2026-04-15	2028-05-10	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
990	12	19	2026-04-15	2028-04-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
991	13	19	2026-04-15	2028-05-10	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
992	24	19	2026-04-15	2028-06-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
993	1	19	2026-04-15	2028-02-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
994	12	19	2026-04-15	2028-04-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
995	24	19	2026-04-15	2028-06-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
996	25	19	2026-04-15	2028-07-28	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
997	1	19	2026-04-15	2028-02-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
998	12	19	2026-04-15	2028-04-03	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
999	13	19	2026-04-15	2028-05-10	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
1000	24	19	2026-04-15	2028-06-21	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
1001	133	9	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1002	127	24	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1003	22	22	2026-05-12	2028-04-08	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1005	145	10	2026-05-12	2028-09-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1006	114	22	2026-05-12	2028-08-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1007	133	22	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1008	137	13	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1009	143	24	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1010	122	10	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1011	146	16	2026-05-12	2028-11-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1012	114	9	2026-05-12	2028-08-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1013	128	12	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1014	108	21	2026-05-12	2028-12-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1015	130	22	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1016	150	16	2026-05-12	2028-03-30	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1017	111	22	2026-05-12	2028-04-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1018	100	10	2026-05-12	2028-03-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1019	124	22	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1020	116	21	2026-05-12	2028-10-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1022	107	10	2026-05-12	2028-11-19	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1023	126	12	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1024	132	16	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1025	121	24	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1026	99	22	2026-05-12	2028-01-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1027	135	10	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1028	130	9	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1029	136	12	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1030	137	21	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1031	119	24	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1032	148	10	2026-05-12	2028-01-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1033	124	9	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1034	111	9	2026-05-12	2028-04-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1035	140	22	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1037	125	12	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1038	123	24	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1039	142	22	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1040	139	16	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1041	110	21	2026-05-12	2028-03-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1042	132	13	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1043	125	10	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1044	113	10	2026-05-12	2028-06-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1045	103	21	2026-05-12	2028-06-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1046	136	10	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1047	148	12	2026-05-12	2028-01-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1048	109	10	2026-05-12	2028-02-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1049	127	22	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1050	118	21	2026-05-12	2028-12-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1051	139	13	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1052	135	12	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1053	143	22	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1054	133	24	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1055	127	9	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1056	126	10	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1057	122	12	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1058	121	22	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1059	132	21	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1060	128	10	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1061	123	9	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1062	124	24	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1063	104	9	2026-05-12	2028-07-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1064	105	21	2026-05-12	2028-09-06	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1065	130	24	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1066	97	22	2026-05-12	2028-11-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1067	101	9	2026-05-12	2028-04-11	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1068	119	9	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1069	121	9	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1071	145	12	2026-05-12	2028-09-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1072	139	21	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1073	142	24	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1074	102	21	2026-05-12	2028-05-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1075	123	22	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1076	104	22	2026-05-12	2028-07-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1077	140	24	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1078	119	22	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1079	137	16	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1080	101	22	2026-05-12	2028-04-11	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1081	128	9	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1082	123	10	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1084	134	21	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1085	129	13	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1086	101	10	2026-05-12	2028-04-11	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1087	119	10	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1088	104	10	2026-05-12	2028-07-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1089	128	22	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1090	131	21	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1091	121	10	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1092	135	24	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1093	133	12	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1094	134	13	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1095	129	21	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1096	113	9	2026-05-12	2028-06-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1097	122	24	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1098	117	21	2026-05-12	2028-11-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1099	125	9	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1100	124	12	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1101	126	22	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1102	109	9	2026-05-12	2028-02-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1103	141	16	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1104	130	12	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1105	144	12	2026-05-12	2028-08-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1106	136	9	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1107	143	10	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1108	147	12	2026-05-12	2028-12-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1109	113	22	2026-05-12	2028-06-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1110	106	21	2026-05-12	2028-10-13	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1111	131	13	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1112	142	12	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1113	125	22	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1114	127	10	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1115	140	12	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1116	126	9	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1117	109	22	2026-05-12	2028-02-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1118	136	22	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1119	120	16	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1120	141	13	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1121	140	10	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1122	127	12	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1123	107	9	2026-05-12	2028-11-19	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1124	134	16	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1126	135	9	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1127	142	10	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1128	124	10	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1129	100	22	2026-05-12	2028-03-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1130	111	10	2026-05-12	2028-04-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1132	107	22	2026-05-12	2028-11-19	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1133	144	10	2026-05-12	2028-08-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1134	130	10	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1135	143	12	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1136	147	10	2026-05-12	2028-12-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1137	120	13	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1138	131	16	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1139	135	22	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1140	99	10	2026-05-12	2028-01-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1141	112	21	2026-05-12	2028-05-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1142	128	24	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1143	149	16	2026-05-12	2028-02-22	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1144	133	10	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1145	141	21	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1146	126	24	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1147	129	16	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1148	121	12	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1149	122	22	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1150	120	21	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1151	136	24	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1152	119	12	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1153	114	10	2026-05-12	2028-08-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1154	98	22	2026-05-12	2028-12-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1155	123	12	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1156	125	24	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1157	33	22	2026-05-12	2028-05-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1158	122	9	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1159	121	16	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1160	99	21	2026-05-12	2028-01-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1161	129	12	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1162	112	10	2026-05-12	2028-05-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1163	132	24	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1165	116	22	2026-05-12	2028-10-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1166	111	21	2026-05-12	2028-04-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1167	124	21	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1168	130	21	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1169	123	16	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1170	142	21	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1171	139	24	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1172	133	13	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1173	116	9	2026-05-12	2028-10-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1174	140	21	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1175	137	22	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1176	119	16	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1177	108	9	2026-05-12	2028-12-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1178	114	21	2026-05-12	2028-08-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1179	134	12	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1180	130	13	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1181	120	10	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1182	127	16	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1183	124	13	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1184	149	12	2026-05-12	2028-02-22	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1185	142	13	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1186	108	22	2026-05-12	2028-12-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1187	131	12	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1188	143	16	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1189	141	10	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1190	133	21	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1191	140	13	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1192	147	16	2026-05-12	2028-12-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1193	130	16	2026-05-12	2028-03-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1194	144	16	2026-05-12	2028-08-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1195	141	12	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1196	105	22	2026-05-12	2028-09-06	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1197	124	16	2026-05-12	2028-08-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1198	127	13	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1199	149	10	2026-05-12	2028-02-22	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1200	102	9	2026-05-12	2028-05-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1201	132	22	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1202	121	21	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1203	131	10	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1204	143	13	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1205	101	21	2026-05-12	2028-04-11	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1206	119	21	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1207	137	24	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1208	120	12	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1209	105	9	2026-05-12	2028-09-06	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1210	140	16	2026-05-12	2028-03-25	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1211	104	21	2026-05-12	2028-07-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1212	139	22	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1213	142	16	2026-05-12	2028-06-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1214	123	21	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1215	102	22	2026-05-12	2028-05-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1216	132	9	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1217	134	10	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1218	127	21	2026-05-12	2028-11-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1219	118	22	2026-05-12	2028-12-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1220	103	22	2026-05-12	2028-06-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1221	121	13	2026-05-12	2028-04-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1222	106	10	2026-05-12	2028-10-13	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1223	110	22	2026-05-12	2028-03-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1224	118	9	2026-05-12	2028-12-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1225	133	16	2026-05-12	2028-07-09	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1226	143	21	2026-05-12	2028-07-14	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1227	103	9	2026-05-12	2028-06-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1228	119	13	2026-05-12	2028-02-07	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1229	117	10	2026-05-12	2028-11-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1230	129	10	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1231	110	9	2026-05-12	2028-03-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1232	123	13	2026-05-12	2028-07-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1233	141	24	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1234	126	21	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1235	117	22	2026-05-12	2028-11-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1236	122	16	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1237	146	10	2026-05-12	2028-11-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1238	129	22	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1240	106	9	2026-05-12	2028-10-13	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1241	137	12	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1242	136	21	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1243	103	10	2026-05-12	2028-06-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1244	120	24	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1245	118	10	2026-05-12	2028-12-31	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1246	109	21	2026-05-12	2028-02-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1247	128	13	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1248	125	21	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1249	145	16	2026-05-12	2028-09-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1250	110	10	2026-05-12	2028-03-10	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1251	117	9	2026-05-12	2028-11-24	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1252	113	21	2026-05-12	2028-06-29	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1253	106	22	2026-05-12	2028-10-13	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1254	129	9	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1255	126	13	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1256	148	16	2026-05-12	2028-01-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1257	134	22	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1259	131	9	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1260	102	10	2026-05-12	2028-05-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1261	139	10	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1262	105	10	2026-05-12	2028-09-06	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1263	136	13	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1264	150	10	2026-05-12	2028-03-30	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1265	135	16	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1266	134	9	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1267	131	22	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1268	132	10	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1269	125	13	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1270	128	21	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1271	122	21	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1272	129	24	2026-05-12	2028-02-12	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1273	108	10	2026-05-12	2028-12-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1274	132	12	2026-05-12	2028-06-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1275	126	16	2026-05-12	2028-10-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1276	141	22	2026-05-12	2028-05-01	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1277	150	12	2026-05-12	2028-03-30	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1278	120	9	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1279	135	13	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1280	125	16	2026-05-12	2028-09-16	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1281	139	12	2026-05-12	2028-02-17	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1282	34	22	2026-05-12	2028-06-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1283	120	22	2026-05-12	2028-03-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1284	136	16	2026-05-12	2028-10-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1285	112	9	2026-05-12	2028-05-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1287	134	24	2026-05-12	2028-08-15	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1288	122	13	2026-05-12	2028-05-28	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1289	137	10	2026-05-12	2028-12-04	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1290	128	16	2026-05-12	2029-01-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1291	112	22	2026-05-12	2028-05-23	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1292	135	21	2026-05-12	2028-09-21	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1293	146	12	2026-05-12	2028-11-02	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1294	131	24	2026-05-12	2028-04-26	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1295	116	10	2026-05-12	2028-10-18	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1296	107	21	2026-05-12	2028-11-19	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1297	100	21	2026-05-12	2028-03-05	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1298	19	11	2026-05-20	2028-12-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1299	20	11	2026-05-20	2028-01-25	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1300	27	11	2026-05-20	2028-10-10	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1301	29	11	2026-05-20	2028-12-23	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1302	30	11	2026-05-20	2028-01-30	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1303	31	11	2026-05-20	2028-03-07	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1304	32	11	2026-05-20	2028-04-13	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1305	39	11	2026-05-20	2028-12-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1306	40	11	2026-05-20	2028-02-04	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1307	57	11	2026-05-20	2028-10-25	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1308	58	11	2026-05-20	2028-12-01	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1309	59	11	2026-05-20	2029-01-07	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1310	60	11	2026-05-20	2028-02-14	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1311	61	11	2026-05-20	2028-03-22	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1312	62	11	2026-05-20	2028-04-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1313	63	11	2026-05-20	2028-06-04	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1314	64	11	2026-05-20	2028-07-11	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1315	65	11	2026-05-20	2028-08-17	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1316	66	11	2026-05-20	2028-09-23	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1317	67	11	2026-05-20	2028-10-30	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1318	68	11	2026-05-20	2028-12-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1320	70	11	2026-05-20	2028-02-19	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1321	71	11	2026-05-20	2028-03-27	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1322	72	11	2026-05-20	2028-05-03	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1323	73	11	2026-05-20	2028-06-09	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1324	74	11	2026-05-20	2028-07-16	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1325	75	11	2026-05-20	2028-08-22	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1326	76	11	2026-05-20	2028-09-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1327	77	11	2026-05-20	2028-11-04	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1328	78	11	2026-05-20	2028-12-11	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1329	79	11	2026-05-20	2028-01-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1330	80	11	2026-05-20	2028-02-24	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1331	81	11	2026-05-20	2028-04-01	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1332	82	11	2026-05-20	2028-05-08	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1333	83	11	2026-05-20	2028-06-14	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1334	84	11	2026-05-20	2028-07-21	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1335	85	11	2026-05-20	2028-08-27	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1336	86	11	2026-05-20	2028-10-03	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1337	87	11	2026-05-20	2028-11-09	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1338	88	11	2026-05-20	2028-12-16	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1339	89	11	2026-05-20	2028-01-23	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1340	90	11	2026-05-20	2028-02-29	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1341	91	11	2026-05-20	2028-04-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1343	93	11	2026-05-20	2028-06-19	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1344	94	11	2026-05-20	2028-07-26	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1345	95	11	2026-05-20	2028-09-01	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1346	96	11	2026-05-20	2028-10-08	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1347	97	11	2026-05-20	2028-11-14	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1348	98	11	2026-05-20	2028-12-21	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1349	99	11	2026-05-20	2028-01-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1350	100	11	2026-05-20	2028-03-05	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1351	101	11	2026-05-20	2028-04-11	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1352	102	11	2026-05-20	2028-05-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1353	103	11	2026-05-20	2028-06-24	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1354	104	11	2026-05-20	2028-07-31	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1355	105	11	2026-05-20	2028-09-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1356	106	11	2026-05-20	2028-10-13	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1357	107	11	2026-05-20	2028-11-19	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1358	108	11	2026-05-20	2028-12-26	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1359	109	11	2026-05-20	2028-02-02	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1360	19	20	2026-05-20	2028-12-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1361	27	20	2026-05-20	2028-10-10	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1362	28	20	2026-05-20	2028-11-16	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1363	29	20	2026-05-20	2028-12-23	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1364	31	20	2026-05-20	2028-03-07	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1365	32	20	2026-05-20	2028-04-13	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1366	39	20	2026-05-20	2028-12-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1367	55	20	2026-05-20	2028-08-12	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1368	56	20	2026-05-20	2028-09-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1369	57	20	2026-05-20	2028-10-25	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1370	58	20	2026-05-20	2028-12-01	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1371	59	20	2026-05-20	2029-01-07	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1372	60	20	2026-05-20	2028-02-14	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1373	61	20	2026-05-20	2028-03-22	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1374	62	20	2026-05-20	2028-04-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1375	63	20	2026-05-20	2028-06-04	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1376	64	20	2026-05-20	2028-07-11	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1377	65	20	2026-05-20	2028-08-17	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1378	66	20	2026-05-20	2028-09-23	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1379	67	20	2026-05-20	2028-10-30	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1380	68	20	2026-05-20	2028-12-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1382	70	20	2026-05-20	2028-02-19	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1383	71	20	2026-05-20	2028-03-27	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1384	72	20	2026-05-20	2028-05-03	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1385	73	20	2026-05-20	2028-06-09	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1386	74	20	2026-05-20	2028-07-16	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1387	75	20	2026-05-20	2028-08-22	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1388	76	20	2026-05-20	2028-09-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1389	77	20	2026-05-20	2028-11-04	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1390	78	20	2026-05-20	2028-12-11	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1391	79	20	2026-05-20	2028-01-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1392	80	20	2026-05-20	2028-02-24	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1393	81	20	2026-05-20	2028-04-01	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1394	82	20	2026-05-20	2028-05-08	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1395	83	20	2026-05-20	2028-06-14	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1396	84	20	2026-05-20	2028-07-21	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1397	85	20	2026-05-20	2028-08-27	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1398	86	20	2026-05-20	2028-10-03	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1399	87	20	2026-05-20	2028-11-09	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1400	88	20	2026-05-20	2028-12-16	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1401	89	20	2026-05-20	2028-01-23	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1402	90	20	2026-05-20	2028-02-29	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1403	91	20	2026-05-20	2028-04-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1405	93	20	2026-05-20	2028-06-19	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1406	94	20	2026-05-20	2028-07-26	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1407	95	20	2026-05-20	2028-09-01	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1408	96	20	2026-05-20	2028-10-08	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1409	97	20	2026-05-20	2028-11-14	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1410	98	20	2026-05-20	2028-12-21	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1411	99	20	2026-05-20	2028-01-28	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1412	100	20	2026-05-20	2028-03-05	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1413	101	20	2026-05-20	2028-04-11	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1414	102	20	2026-05-20	2028-05-18	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1415	103	20	2026-05-20	2028-06-24	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1416	104	20	2026-05-20	2028-07-31	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1417	105	20	2026-05-20	2028-09-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1418	106	20	2026-05-20	2028-10-13	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1419	107	20	2026-05-20	2028-11-19	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1420	108	20	2026-05-20	2028-12-26	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1421	109	20	2026-05-20	2028-02-02	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
23	23	5	2025-12-24	2027-04-28	active	\N	\N	\N	приказ № 12 (условный)	\N	2026-08-24 14:54:07.128601+07	2026-09-13 11:12:17.830107+07	\N	\N
658	46	5	2026-02-10	2027-05-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
659	46	6	2026-02-10	2027-05-11	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
704	69	5	2026-02-10	2027-05-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
705	69	6	2026-02-10	2027-05-24	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1494	46	25	2025-01-15	2027-05-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1495	46	26	2025-01-15	2027-05-11	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
750	92	5	2026-02-10	2027-06-06	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
1540	69	25	2025-01-15	2027-05-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1541	69	26	2025-01-15	2027-05-24	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1586	92	25	2025-01-15	2027-06-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
1587	92	26	2025-01-15	2027-06-06	active	\N	\N	\N	\N	\N	2026-09-13 10:40:56.212302+07	2026-09-13 11:12:17.830107+07	\N	\N
796	115	5	2026-02-10	2027-04-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
797	115	6	2026-02-10	2027-04-20	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
842	138	5	2026-02-10	2027-05-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
843	138	6	2026-02-10	2027-05-03	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
888	161	5	2026-02-10	2027-05-16	active	\N	\N	\N	приказ № 61 от 10.02.2026	\N	2026-09-07 14:42:17.371118+07	2026-09-13 11:12:17.830107+07	\N	8
340	23	16	2026-03-05	2027-04-28	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
402	23	10	2026-03-05	2027-04-28	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
479	92	17	2026-03-05	2027-06-06	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
496	46	18	2026-03-05	2027-05-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
507	46	18	2026-03-05	2027-05-11	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
543	23	12	2026-03-05	2027-04-28	active	\N	\N	\N	приказ № 62 от 05.03.2026	\N	2026-09-07 14:37:09.148109+07	2026-09-13 11:12:17.830107+07	\N	6
909	115	16	2026-04-15	2027-04-20	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
913	115	24	2026-04-15	2027-04-20	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
967	69	18	2026-04-15	2027-05-24	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
971	69	18	2026-04-15	2027-05-24	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
972	115	12	2026-04-15	2027-04-20	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
976	115	13	2026-04-15	2027-04-20	active	\N	\N	\N	приказ № 64 от 15.04.2026	\N	2026-09-07 14:45:00.655918+07	2026-09-13 11:12:17.830107+07	\N	9
1004	138	12	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1021	115	22	2026-05-12	2027-04-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1036	115	9	2026-05-12	2027-04-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1070	138	10	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1083	138	22	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1125	138	24	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1131	115	10	2026-05-12	2027-04-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1164	115	21	2026-05-12	2027-04-20	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1239	138	13	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1258	138	21	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1286	138	16	2026-05-12	2027-05-03	active	\N	\N	\N	приказ № 65 от 12.05.2026	\N	2026-09-07 14:46:52.449533+07	2026-09-13 11:12:17.830107+07	\N	10
1319	69	11	2026-05-20	2027-05-24	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1342	92	11	2026-05-20	2027-06-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1381	69	20	2026-05-20	2027-05-24	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
1404	92	20	2026-05-20	2027-06-06	active	\N	\N	\N	приказ № 66 от 20.05.2026	\N	2026-09-07 14:47:53.58625+07	2026-09-13 11:12:17.830107+07	\N	11
\.


--
-- Data for Name: employee_post_weights; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.employee_post_weights (employee_id, post_id, weight, note, updated_by, updated_at) FROM stdin;
\.


--
-- Data for Name: employees; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.employees (id, last_name, first_name, middle_name, rank_id, "position", unit_id, personnel_number, phone, email, is_active, created_at, updated_at, excluded_on, exclusion_reason) FROM stdin;
62	Панкратов	Виктор	Леонидович	2	Заместитель командира отделения	20	С-01022	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
2	Белов	Виктор	Викторович	2	механик	4	Т-0002	+7 (900) 102-00-02	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
3	Волков	Григорий	Григорьевич	3	радиотелефонист	5	Т-0003	+7 (900) 103-00-03	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
41	Зотов	Евгений	Олегович	1	Наводчик-оператор	27	С-01001	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
5	Данилов	Евгений	Евгеньевич	4	Командир отделения	17	Т-0005	+7 (900) 105-00-05	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
6	Ершов	Иван	Иванович	5	командир отделения	4	Т-0006	+7 (900) 106-00-06	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
7	Жданов	Кирилл	Кириллович	6	заместитель командира взвода	5	Т-0007	+7 (900) 107-00-07	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
56	Зотов	Леонид	Сергеевич	2	Заместитель командира отделения	17	С-01016	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
25	Щукин	Михаил	Борисович	1	Наводчик-оператор	17	Т-0025	+7 (900) 125-00-25	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
10	Кабанов	Николай	Николаевич	12	механик	4	Т-0010	+7 (900) 110-00-10	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
11	Лебедев	Олег	Олегович	13	радиотелефонист	5	Т-0011	+7 (900) 111-00-11	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
90	Абрамов	Фёдор	Николаевич	6	Командир отделения	12	С-01050	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
74	Бобров	Леонид	Сергеевич	4	Заместитель командира отделения	12	С-01034	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
14	Орлов	Сергей	Викторович	2	командир отделения	4	Т-0014	+7 (900) 114-00-14	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
15	Панов	Тимофей	Григорьевич	3	заместитель командира взвода	5	Т-0015	+7 (900) 115-00-15	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
64	Бобров	Павел	Павлович	2	Наводчик-оператор	12	С-01024	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
46	Зотов	Павел	Павлович	1	Механик-водитель	12	С-01006	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
18	Тарасов	Виктор	Иванович	5	механик	4	Т-0018	+7 (900) 118-00-18	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
19	Ушаков	Григорий	Кириллович	6	радиотелефонист	5	Т-0019	+7 (900) 119-00-19	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
17	Сафонов	Борис	Евгеньевич	4	Командир отделения	18	Т-0017	+7 (900) 117-00-17	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
58	Цветков	Александр	Александрович	2	Заместитель командира отделения	18	С-01018	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
22	Цветков	Иван	Николаевич	12	командир отделения	4	Т-0022	+7 (900) 122-00-22	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
23	Чернов	Кирилл	Олегович	13	заместитель командира взвода	5	Т-0023	+7 (900) 123-00-23	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
37	Крылов	Евгений	Борисович	1	Наводчик-оператор	18	Т-0037	+7 (900) 137-00-37	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
82	Панкратов	Павел	Павлович	5	Командир отделения	15	С-01042	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
26	Юдин	Николай	Викторович	2	механик	4	Т-0026	+7 (900) 126-00-26	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
27	Яковлев	Олег	Григорьевич	3	радиотелефонист	5	Т-0027	+7 (900) 127-00-27	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
70	Абрамов	Игорь	Игоревич	3	Заместитель командира отделения	15	С-01030	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
1	Абрамов	Борис	Борисович	1	Наводчик-оператор	15	Т-0001	+7 (900) 101-00-01	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
30	Виноградов	Сергей	Иванович	5	командир отделения	4	Т-0030	+7 (900) 130-00-30	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
31	Головин	Тимофей	Кириллович	6	заместитель командира взвода	5	Т-0031	+7 (900) 131-00-31	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
52	Панкратов	Игорь	Игоревич	1	Механик-водитель	15	С-01012	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
92	Панкратов	Леонид	Сергеевич	6	Командир отделения	13	С-01052	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
34	Жуков	Виктор	Николаевич	12	механик	4	Т-0034	+7 (900) 134-00-34	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
35	Зимин	Григорий	Олегович	13	радиотелефонист	5	Т-0035	+7 (900) 135-00-35	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
76	Зотов	Александр	Александрович	4	Заместитель командира отделения	13	С-01036	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
66	Зотов	Дмитрий	Фёдорович	2	Наводчик-оператор	13	С-01026	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
38	Лукин	Иван	Викторович	2	командир отделения	4	Т-0038	+7 (900) 138-00-38	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
39	Медведев	Кирилл	Григорьевич	3	заместитель командира взвода	5	Т-0039	+7 (900) 139-00-39	\N	t	2026-08-24 14:54:07.128601+07	2026-08-24 14:54:07.128601+07	\N	\N
48	Цветков	Дмитрий	Фёдорович	1	Механик-водитель	13	С-01008	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
91	Зотов	Геннадий	Геннадьевич	6	Командир отделения	21	С-01051	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
16	Рыбаков	Александр	Дмитриевич	3	Заместитель командира отделения	21	Т-0016	+7 (900) 116-00-16	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
65	Абрамов	Юрий	Евгеньевич	2	Наводчик-оператор	21	С-01025	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
47	Панкратов	Юрий	Евгеньевич	1	Механик-водитель	21	С-01007	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
29	Баранов	Роман	Евгеньевич	4	Командир отделения	19	Т-0029	+7 (900) 129-00-29	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
60	Абрамов	Николай	Дмитриевич	2	Заместитель командира отделения	19	С-01020	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
42	Панкратов	Николай	Дмитриевич	1	Наводчик-оператор	19	С-01002	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
53	Цветков	Олег	Юрьевич	1	Механик-водитель	24	С-01013	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
83	Цветков	Юрий	Евгеньевич	5	Командир отделения	24	С-01043	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
71	Зотов	Олег	Юрьевич	3	Заместитель командира отделения	24	С-01031	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
12	Морозов	Павел	Александрович	1	Наводчик-оператор	24	Т-0012	+7 (900) 112-00-12	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
77	Панкратов	Евгений	Олегович	4	Командир отделения	28	С-01037	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
61	Зотов	Тимур	Тимурович	2	Заместитель командира отделения	28	С-01021	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
43	Цветков	Тимур	Тимурович	1	Наводчик-оператор	28	С-01003	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
4	Гусев	Дмитрий	Дмитриевич	3	Командир отделения	29	Т-0004	+7 (900) 104-00-04	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
63	Цветков	Кирилл	Борисович	2	Заместитель командира отделения	29	С-01023	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
45	Абрамов	Кирилл	Борисович	1	Наводчик-оператор	29	С-01005	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
84	Бобров	Дмитрий	Фёдорович	5	Командир отделения	16	С-01044	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
54	Бобров	Фёдор	Николаевич	2	Заместитель командира отделения	16	С-01014	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
13	Никитин	Роман	Борисович	1	Наводчик-оператор	16	Т-0013	+7 (900) 113-00-13	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
81	Зотов	Кирилл	Борисович	5	Командир отделения	23	С-01041	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
40	Носов	Леонид	Дмитриевич	3	Заместитель командира отделения	23	Т-0040	+7 (900) 140-00-40	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
69	Бобров	Борис	Романович	2	Наводчик-оператор	23	С-01029	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
51	Зотов	Борис	Романович	1	Механик-водитель	23	С-01011	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
79	Бобров	Тимур	Тимурович	5	Командир отделения	22	С-01039	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
28	Антонов	Павел	Дмитриевич	3	Заместитель командира отделения	22	Т-0028	+7 (900) 128-00-28	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
67	Панкратов	Максим	Максимович	2	Наводчик-оператор	22	С-01027	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
49	Бобров	Максим	Максимович	1	Механик-водитель	22	С-01009	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
80	Абрамов	Виктор	Леонидович	5	Командир отделения	14	С-01040	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
78	Цветков	Николай	Дмитриевич	4	Заместитель командира отделения	14	С-01038	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
68	Цветков	Сергей	Викторович	2	Наводчик-оператор	14	С-01028	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
50	Абрамов	Сергей	Викторович	1	Механик-водитель	14	С-01010	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
142	Панкратов	Игорь	Игоревич	12	начальник службы	33	С-01102	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 16:27:07.944321+07	\N	\N
93	Цветков	Роман	Кириллович	7	техник	5	С-01053	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
94	Бобров	Александр	Александрович	7	техник	4	С-01054	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
95	Абрамов	Евгений	Олегович	7	техник	5	С-01055	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
96	Зотов	Николай	Дмитриевич	7	техник	4	С-01056	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
97	Панкратов	Тимур	Тимурович	7	техник	5	С-01057	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
98	Цветков	Виктор	Леонидович	7	техник	4	С-01058	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
99	Бобров	Кирилл	Борисович	7	техник	5	С-01059	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
100	Абрамов	Павел	Павлович	8	техник	4	С-01060	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
101	Зотов	Юрий	Евгеньевич	8	техник	5	С-01061	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
102	Панкратов	Дмитрий	Фёдорович	8	техник	4	С-01062	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
103	Цветков	Максим	Максимович	8	техник	5	С-01063	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
104	Бобров	Сергей	Викторович	8	техник	4	С-01064	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
105	Абрамов	Борис	Романович	8	техник	5	С-01065	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
106	Зотов	Игорь	Игоревич	8	техник	4	С-01066	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
107	Панкратов	Олег	Юрьевич	8	техник	5	С-01067	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
108	Цветков	Фёдор	Николаевич	8	техник	4	С-01068	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
109	Бобров	Геннадий	Геннадьевич	8	техник	5	С-01069	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
110	Абрамов	Леонид	Сергеевич	9	командир взвода	4	С-01070	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
111	Зотов	Роман	Кириллович	9	командир взвода	5	С-01071	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
112	Панкратов	Александр	Александрович	9	командир взвода	4	С-01072	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
113	Цветков	Евгений	Олегович	9	командир взвода	5	С-01073	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
114	Бобров	Николай	Дмитриевич	9	командир взвода	4	С-01074	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
115	Абрамов	Тимур	Тимурович	9	командир взвода	5	С-01075	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
116	Зотов	Виктор	Леонидович	9	командир взвода	4	С-01076	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
117	Панкратов	Кирилл	Борисович	9	командир взвода	5	С-01077	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
118	Цветков	Павел	Павлович	9	командир взвода	4	С-01078	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
119	Бобров	Юрий	Евгеньевич	9	командир взвода	5	С-01079	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
120	Абрамов	Дмитрий	Фёдорович	10	командир взвода	4	С-01080	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
121	Зотов	Максим	Максимович	10	командир взвода	5	С-01081	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
122	Панкратов	Сергей	Викторович	10	командир взвода	4	С-01082	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
123	Цветков	Борис	Романович	10	командир взвода	5	С-01083	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
124	Бобров	Игорь	Игоревич	10	командир взвода	4	С-01084	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
125	Абрамов	Олег	Юрьевич	10	командир взвода	5	С-01085	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
126	Зотов	Фёдор	Николаевич	10	командир взвода	4	С-01086	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
127	Панкратов	Геннадий	Геннадьевич	11	командир взвода	5	С-01087	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
128	Цветков	Леонид	Сергеевич	11	командир взвода	4	С-01088	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
129	Бобров	Роман	Кириллович	11	командир взвода	5	С-01089	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
130	Абрамов	Александр	Александрович	11	командир взвода	4	С-01090	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
131	Зотов	Евгений	Олегович	11	командир взвода	5	С-01091	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
132	Панкратов	Николай	Дмитриевич	11	командир взвода	4	С-01092	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
133	Цветков	Тимур	Тимурович	11	командир взвода	5	С-01093	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
134	Бобров	Виктор	Леонидович	11	командир взвода	4	С-01094	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
135	Абрамов	Кирилл	Борисович	11	командир взвода	5	С-01095	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
136	Зотов	Павел	Павлович	11	командир взвода	4	С-01096	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
137	Панкратов	Юрий	Евгеньевич	12	начальник службы	4	С-01097	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
138	Цветков	Дмитрий	Фёдорович	12	начальник службы	5	С-01098	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
171	Кравцов	Олег	Николаевич	14	Начальник штаба	50	\N	\N	\N	t	2026-09-27 14:49:18.755948+07	2026-09-27 14:49:18.755948+07	\N	\N
140	Абрамов	Сергей	Викторович	12	начальник службы	4	С-01100	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
141	Зотов	Борис	Романович	12	начальник службы	5	С-01101	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
143	Цветков	Олег	Юрьевич	12	начальник службы	4	С-01103	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
144	Бобров	Фёдор	Николаевич	13	начальник службы	5	С-01104	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
146	Зотов	Леонид	Сергеевич	13	начальник службы	4	С-01106	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
147	Панкратов	Роман	Кириллович	13	начальник службы	5	С-01107	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
149	Бобров	Евгений	Олегович	13	начальник службы	4	С-01109	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
150	Абрамов	Николай	Дмитриевич	13	начальник службы	5	С-01110	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-07 14:37:09.148109+07	\N	\N
152	Панкратов	Виктор	Леонидович	14	заместитель командира части	33	С-01112	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:44.485428+07	\N	\N
153	Цветков	Кирилл	Борисович	14	заместитель командира части	33	С-01113	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:48.511805+07	\N	\N
145	Абрамов	Геннадий	Геннадьевич	13	начальник службы	33	С-01105	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:52.516806+07	\N	\N
148	Цветков	Александр	Александрович	13	начальник службы	33	С-01108	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:54.40406+07	\N	\N
139	Бобров	Максим	Максимович	12	начальник службы	33	С-01099	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:56.165305+07	\N	\N
72	Панкратов	Фёдор	Николаевич	4	Командир отделения	20	С-01032	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
172	Белов	Андрей	Викторович	13	Заместитель начальника штаба	50	\N	\N	\N	t	2026-09-27 14:49:18.755948+07	2026-09-27 14:49:18.755948+07	\N	\N
173	Соколова	Ирина	Петровна	7	Делопроизводитель	50	\N	\N	\N	t	2026-09-27 14:49:18.755948+07	2026-09-27 14:49:18.755948+07	\N	\N
170	Абрамов	Виктор	Леонидович	15	заместитель командира части	33	С-01130	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 14:54:10.819604+07	\N	\N
9	Ильин	Михаил	Михайлович	10	водитель	2	Т-0009	+7 (900) 109-00-09	\N	t	2026-08-24 14:54:07.128601+07	2026-09-13 12:58:06.823516+07	\N	\N
21	Харитонов	Евгений	Михайлович	10	старший техник	2	Т-0021	+7 (900) 121-00-21	\N	t	2026-08-24 14:54:07.128601+07	2026-09-13 12:58:06.823516+07	\N	\N
33	Егоров	Борис	Михайлович	10	водитель	6	Т-0033	+7 (900) 133-00-33	\N	t	2026-08-24 14:54:07.128601+07	2026-09-13 12:58:06.823516+07	\N	\N
86	Зотов	Сергей	Викторович	6	командир отделения	7	С-01046	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-13 12:58:06.823516+07	\N	\N
88	Цветков	Игорь	Игоревич	6	командир отделения	8	С-01048	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-13 12:58:06.823516+07	\N	\N
164	Бобров	Леонид	Сергеевич	15	заместитель командира части	33	С-01124	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:04:20.405301+07	\N	\N
169	Бобров	Тимур	Тимурович	15	заместитель командира части	33	С-01129	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:04:24.259577+07	\N	\N
166	Зотов	Александр	Александрович	15	заместитель командира части	33	С-01126	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:04:28.079779+07	\N	\N
161	Зотов	Олег	Юрьевич	15	заместитель командира части	33	С-01121	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:04:30.639777+07	\N	\N
162	Панкратов	Фёдор	Николаевич	15	заместитель командира части	33	С-01122	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:04:33.237466+07	\N	\N
167	Панкратов	Евгений	Олегович	15	заместитель командира части	33	С-01127	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:18.785341+07	\N	\N
163	Цветков	Геннадий	Геннадьевич	15	заместитель командира части	33	С-01123	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:22.556247+07	\N	\N
168	Цветков	Николай	Дмитриевич	15	заместитель командира части	33	С-01128	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:24.611854+07	\N	\N
160	Абрамов	Игорь	Игоревич	14	заместитель командира части	33	С-01120	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:26.426129+07	\N	\N
155	Абрамов	Юрий	Евгеньевич	14	заместитель командира части	33	С-01115	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:28.532607+07	\N	\N
159	Бобров	Борис	Романович	14	заместитель командира части	33	С-01119	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:30.573173+07	\N	\N
154	Бобров	Павел	Павлович	14	заместитель командира части	33	С-01114	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:33.424573+07	\N	\N
156	Зотов	Дмитрий	Фёдорович	14	заместитель командира части	33	С-01116	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:36.050813+07	\N	\N
157	Панкратов	Максим	Максимович	14	заместитель командира части	33	С-01117	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:46.682137+07	\N	\N
158	Цветков	Сергей	Викторович	14	заместитель командира части	33	С-01118	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:50.326813+07	\N	\N
8	Зайцев	Леонид	Леонидович	7	стрелок	3	Т-0008	+7 (900) 108-00-08	\N	t	2026-08-24 14:54:07.128601+07	2026-09-13 12:58:06.823516+07	\N	\N
20	Фомин	Дмитрий	Леонидович	7	оператор	3	Т-0020	+7 (900) 120-00-20	\N	t	2026-08-24 14:54:07.128601+07	2026-09-13 12:58:06.823516+07	\N	\N
32	Дроздов	Александр	Леонидович	7	стрелок	9	Т-0032	+7 (900) 132-00-32	\N	t	2026-08-24 14:54:07.128601+07	2026-09-13 12:58:06.823516+07	\N	\N
87	Панкратов	Борис	Романович	6	командир отделения	10	С-01047	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-13 12:58:06.823516+07	\N	\N
89	Бобров	Олег	Юрьевич	6	командир отделения	11	С-01049	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-13 12:58:06.823516+07	\N	\N
151	Зотов	Тимур	Тимурович	14	заместитель командира части	33	С-01111	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-19 14:05:42.377453+07	\N	\N
44	Бобров	Виктор	Леонидович	1	Наводчик-оператор	20	С-01004	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
85	Абрамов	Максим	Максимович	5	Командир отделения	25	С-01045	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
55	Абрамов	Геннадий	Геннадьевич	2	Заместитель командира отделения	25	С-01015	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
24	Шилов	Леонид	Александрович	1	Наводчик-оператор	25	Т-0024	+7 (900) 124-00-24	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
73	Цветков	Геннадий	Геннадьевич	4	Командир отделения	26	С-01033	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
57	Панкратов	Роман	Кириллович	2	Заместитель командира отделения	26	С-01017	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
36	Исаев	Дмитрий	Александрович	1	Наводчик-оператор	26	Т-0036	+7 (900) 136-00-36	\N	t	2026-08-24 14:54:07.128601+07	2026-09-27 13:59:22.24411+07	\N	\N
75	Абрамов	Роман	Кириллович	4	Командир отделения	27	С-01035	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
59	Бобров	Евгений	Олегович	2	Заместитель командира отделения	27	С-01019	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 13:59:22.24411+07	\N	\N
165	Абрамов	Роман	Кириллович	15	Командир части	1	С-01125	\N	\N	t	2026-09-07 14:37:09.148109+07	2026-09-27 14:31:01.794093+07	\N	\N
174	Иванов	Иван	Иванович	13	\N	\N	АА-131313	+79999999999	\N	t	2026-09-27 16:11:02.312102+07	2026-09-27 16:26:33.651983+07	\N	\N
\.


--
-- Data for Name: permit_directions; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.permit_directions (id, parent_id, name, sort_order, is_active, created_at) FROM stdin;
1	\N	Суточный наряд	10	t	2026-09-20 19:49:24.095961+07
2	\N	Оперативное дежурство	20	t	2026-09-20 19:49:24.095961+07
3	\N	Охрана и оборона	30	t	2026-09-20 19:49:24.095961+07
4	\N	Медицинские и психологические допуски	40	t	2026-09-20 19:49:24.095961+07
5	\N	Прочие приказы	90	t	2026-09-20 19:49:24.095961+07
\.


--
-- Data for Name: permit_orders; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.permit_orders (id, number, issued_on, title, note, created_at, updated_at, direction_id, file_name, file_path, file_mime, file_size, pdf_path, pdf_error, source, parsed_at, created_by, kind, profile_id) FROM stdin;
4	54	2026-08-20	О допуске к постам суточного наряда (дополнение к приказам № 51—53)	\N	2026-09-07 14:16:51.353616+07	2026-09-20 19:49:24.095961+07	1	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
1	51	2026-01-24	О допуске личного состава к несению службы в суточном наряде	\N	2026-08-24 15:32:26.129808+07	2026-09-20 19:49:24.095961+07	1	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
11	66	2026-05-20	О допуске к постам операторов оперативного дежурства	\N	2026-09-07 14:47:53.58625+07	2026-09-20 19:49:24.095961+07	2	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
2	52	2026-03-24	О допуске личного состава к оперативному дежурству	\N	2026-08-24 15:32:26.129808+07	2026-09-20 19:49:24.095961+07	2	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
10	65	2026-05-12	О допуске офицеров и прапорщиков к старшим постам суточного наряда, ОД и ДСОО	\N	2026-09-07 14:46:52.449533+07	2026-09-20 19:49:24.095961+07	3	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
6	62	2026-03-05	О допуске к постам суточного наряда, ОД и ДСОО	\N	2026-09-07 14:37:09.148109+07	2026-09-20 19:49:24.095961+07	3	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
3	53	2026-04-24	О допуске личного состава к несению службы в дежурной смене	\N	2026-08-24 15:32:26.129808+07	2026-09-20 19:49:24.095961+07	3	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
8	61-1	2026-02-10	О допуске личного состава по результатам УМО/ВВК и МПФО	\N	2026-09-07 14:42:17.371118+07	2026-09-20 19:49:24.095961+07	4	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
5	61	2026-02-10	О допуске личного состава по результатам УМО и МПФО	\N	2026-09-07 14:37:09.148109+07	2026-09-20 19:49:24.095961+07	4	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
9	64	2026-04-15	О дополнительном допуске к постам	\N	2026-09-07 14:45:00.655918+07	2026-09-20 19:49:24.095961+07	5	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
7	63	2026-03-20	О допуске к постам (приведение в соответствие занимаемым должностям)	\N	2026-09-07 14:40:30.726159+07	2026-09-20 19:49:24.095961+07	5	\N	\N	\N	\N	\N	\N	manual	\N	\N	permit	\N
14	77	2026-09-20	О допуске личного состава к несению службы в суточном наряде	Тестовый приказ, данные синтетические	2026-09-20 20:15:58.067111+07	2026-09-20 20:15:58.07453+07	1	prikaz-77.docx	storage/permit-orders/2026/1789910157771-vc40ai.docx	application/vnd.openxmlformats-officedocument.wordprocessingml.document	7190	storage/permit-orders/2026/1789910157771-vc40ai.pdf	\N	manual	\N	\N	permit	\N
\.


--
-- Data for Name: permit_types; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.permit_types (id, code, name, default_validity_months, is_post_specific, notify_days_before, is_active) FROM stdin;
3	WORK_CTRL	Контроль работ	12	f	30	t
4	TECH	Работы с техникой	12	f	30	t
5	UMO_VVK	УМО / ВВК (медицинский допуск)	12	f	30	t
6	MPFO	МПФО (допуск психолога)	60	f	60	t
7	DIRECT	Непосредственный допуск	\N	f	7	t
1	SN	Суточный наряд	12	t	30	t
2	OO	Охрана и оборона	12	t	30	t
8	ROLE_11	Помощник дежурного по парку	12	f	30	t
9	ROLE_7	Помощник дежурного по части	12	f	30	t
10	ROLE_6	Дежурный по части	12	f	30	t
11	ROLE_4	Старший оператор	12	f	30	t
12	ROLE_18	Командир дежурной смены	12	f	30	t
13	ROLE_19	Заместитель командира дежурной смены	12	f	30	t
14	ROLE_9	Помощник дежурного по КПП	12	f	30	t
15	ROLE_8	Дежурный по КПП	12	f	30	t
16	ROLE_1	Оперативный дежурный	12	f	30	t
17	ROLE_12	Дежурный по роте	12	f	30	t
18	ROLE_14	Дневальный по роте	12	f	30	t
19	ROLE_21	Номер расчета	12	f	30	t
20	ROLE_5	Оператор	12	f	30	t
21	ROLE_20	Начальник ПНР	12	f	30	t
22	ROLE_3	Помощник оперативного дежурного	12	f	30	t
23	ROLE_10	Дежурный по парку	12	f	30	t
24	ROLE_2	Старший помощник оперативного дежурного	12	f	30	t
25	ROLE_PTSO	Пост технических средств охраны	12	f	30	t
26	ROLE_PUD	Пост управления доступом	12	f	30	t
\.


--
-- Data for Name: weapon_reservations; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.weapon_reservations (id, weapon_id, employee_id, date_from, date_to, reason, order_id, created_by, created_at, cancelled_at) FROM stdin;
\.


--
-- Data for Name: weapons; Type: TABLE DATA; Schema: personnel; Owner: -
--

COPY personnel.weapons (id, name, serial_number, manufactured_on, kind, owner_id, is_active, unit_id, sort_order) FROM stdin;
169	АК-74М	СК-А-001	2006-02-01	rifle	\N	t	\N	10
170	АК-74М	СК-А-002	2007-03-01	rifle	\N	t	\N	20
171	АК-74М	СК-А-003	2008-04-01	rifle	\N	t	\N	30
172	АК-74М	СК-А-004	2009-05-01	rifle	\N	t	\N	40
173	АК-74М	СК-А-005	2010-06-01	rifle	\N	t	\N	50
174	АК-74М	СК-А-006	2011-07-01	rifle	\N	t	\N	60
175	АК-74М	СК-А-007	2012-08-01	rifle	\N	t	\N	70
176	АК-74М	СК-А-008	2013-09-01	rifle	\N	t	\N	80
177	АК-74М	СК-А-009	2014-10-01	rifle	\N	t	\N	90
178	АК-74М	СК-А-010	2015-11-01	rifle	\N	t	\N	100
179	АК-74М	СК-А-011	2016-12-01	rifle	\N	t	\N	110
180	АК-74М	СК-А-012	2017-01-01	rifle	\N	t	\N	120
181	АК-74М	СК-А-013	2018-02-01	rifle	\N	t	\N	130
182	АК-74М	СК-А-014	2019-03-01	rifle	\N	t	\N	140
183	АК-74М	СК-А-015	2005-04-01	rifle	\N	t	\N	150
184	АК-74М	СК-А-016	2006-05-01	rifle	\N	t	\N	160
185	АК-74М	СК-А-017	2007-06-01	rifle	\N	t	\N	170
186	АК-74М	СК-А-018	2008-07-01	rifle	\N	t	\N	180
187	АК-74М	СК-А-019	2009-08-01	rifle	\N	t	\N	190
188	АК-74М	СК-А-020	2010-09-01	rifle	\N	t	\N	200
189	ПМ	СК-П-001	2008-02-01	pistol	\N	t	\N	210
190	ПМ	СК-П-002	2011-03-01	pistol	\N	t	\N	220
191	ПМ	СК-П-003	2014-04-01	pistol	\N	t	\N	230
192	ПМ	СК-П-004	2017-05-01	pistol	\N	t	\N	240
193	ПМ	СК-П-005	2005-06-01	pistol	\N	t	\N	250
137	Учебный пистолет	TEST-139	2024-01-01	pistol	\N	t	33	10
140	Учебный пистолет	TEST-142	2024-01-01	pistol	\N	t	33	20
163	Учебный пистолет	TEST-165	2024-01-01	pistol	165	t	1	10
19	Учебный пистолет	TEST-21	2024-01-01	pistol	21	t	2	10
8	Учебный пистолет	TEST-9	2024-01-01	pistol	9	t	2	20
18	Учебный автомат	TEST-20	2024-01-01	rifle	20	t	3	10
7	Учебный автомат	TEST-8	2024-01-01	rifle	8	t	3	20
9	Учебный пистолет	TEST-10	2024-01-01	pistol	10	t	4	10
108	Учебный пистолет	TEST-110	2024-01-01	pistol	110	t	4	20
110	Учебный пистолет	TEST-112	2024-01-01	pistol	112	t	4	30
112	Учебный пистолет	TEST-114	2024-01-01	pistol	114	t	4	40
114	Учебный пистолет	TEST-116	2024-01-01	pistol	116	t	4	50
116	Учебный пистолет	TEST-118	2024-01-01	pistol	118	t	4	60
118	Учебный пистолет	TEST-120	2024-01-01	pistol	120	t	4	70
120	Учебный пистолет	TEST-122	2024-01-01	pistol	122	t	4	80
122	Учебный пистолет	TEST-124	2024-01-01	pistol	124	t	4	90
124	Учебный пистолет	TEST-126	2024-01-01	pistol	126	t	4	100
126	Учебный пистолет	TEST-128	2024-01-01	pistol	128	t	4	110
128	Учебный пистолет	TEST-130	2024-01-01	pistol	130	t	4	120
130	Учебный пистолет	TEST-132	2024-01-01	pistol	132	t	4	130
132	Учебный пистолет	TEST-134	2024-01-01	pistol	134	t	4	140
134	Учебный пистолет	TEST-136	2024-01-01	pistol	136	t	4	150
135	Учебный пистолет	TEST-137	2024-01-01	pistol	137	t	4	160
138	Учебный пистолет	TEST-140	2024-01-01	pistol	140	t	4	170
141	Учебный пистолет	TEST-143	2024-01-01	pistol	143	t	4	180
144	Учебный пистолет	TEST-146	2024-01-01	pistol	146	t	4	190
147	Учебный пистолет	TEST-149	2024-01-01	pistol	149	t	4	200
20	Учебный пистолет	TEST-22	2024-01-01	pistol	22	t	4	210
32	Учебный пистолет	TEST-34	2024-01-01	pistol	34	t	4	220
98	Учебный автомат	TEST-100	2024-01-01	rifle	100	t	4	230
100	Учебный автомат	TEST-102	2024-01-01	rifle	102	t	4	240
102	Учебный автомат	TEST-104	2024-01-01	rifle	104	t	4	250
104	Учебный автомат	TEST-106	2024-01-01	rifle	106	t	4	260
106	Учебный автомат	TEST-108	2024-01-01	rifle	108	t	4	270
12	Учебный автомат	TEST-14	2024-01-01	rifle	14	t	4	280
16	Учебный автомат	TEST-18	2024-01-01	rifle	18	t	4	290
1	Учебный автомат	TEST-2	2024-01-01	rifle	2	t	4	300
24	Учебный автомат	TEST-26	2024-01-01	rifle	26	t	4	310
28	Учебный автомат	TEST-30	2024-01-01	rifle	30	t	4	320
36	Учебный автомат	TEST-38	2024-01-01	rifle	38	t	4	330
5	Учебный автомат	TEST-6	2024-01-01	rifle	6	t	4	340
92	Учебный автомат	TEST-94	2024-01-01	rifle	94	t	4	350
94	Учебный автомат	TEST-96	2024-01-01	rifle	96	t	4	360
96	Учебный автомат	TEST-98	2024-01-01	rifle	98	t	4	370
10	Учебный пистолет	TEST-11	2024-01-01	pistol	11	t	5	10
109	Учебный пистолет	TEST-111	2024-01-01	pistol	111	t	5	20
111	Учебный пистолет	TEST-113	2024-01-01	pistol	113	t	5	30
113	Учебный пистолет	TEST-115	2024-01-01	pistol	115	t	5	40
115	Учебный пистолет	TEST-117	2024-01-01	pistol	117	t	5	50
117	Учебный пистолет	TEST-119	2024-01-01	pistol	119	t	5	60
119	Учебный пистолет	TEST-121	2024-01-01	pistol	121	t	5	70
121	Учебный пистолет	TEST-123	2024-01-01	pistol	123	t	5	80
123	Учебный пистолет	TEST-125	2024-01-01	pistol	125	t	5	90
125	Учебный пистолет	TEST-127	2024-01-01	pistol	127	t	5	100
127	Учебный пистолет	TEST-129	2024-01-01	pistol	129	t	5	110
129	Учебный пистолет	TEST-131	2024-01-01	pistol	131	t	5	120
131	Учебный пистолет	TEST-133	2024-01-01	pistol	133	t	5	130
133	Учебный пистолет	TEST-135	2024-01-01	pistol	135	t	5	140
136	Учебный пистолет	TEST-138	2024-01-01	pistol	138	t	5	150
139	Учебный пистолет	TEST-141	2024-01-01	pistol	141	t	5	160
142	Учебный пистолет	TEST-144	2024-01-01	pistol	144	t	5	170
145	Учебный пистолет	TEST-147	2024-01-01	pistol	147	t	5	180
148	Учебный пистолет	TEST-150	2024-01-01	pistol	150	t	5	190
21	Учебный пистолет	TEST-23	2024-01-01	pistol	23	t	5	200
33	Учебный пистолет	TEST-35	2024-01-01	pistol	35	t	5	210
99	Учебный автомат	TEST-101	2024-01-01	rifle	101	t	5	220
101	Учебный автомат	TEST-103	2024-01-01	rifle	103	t	5	230
103	Учебный автомат	TEST-105	2024-01-01	rifle	105	t	5	240
105	Учебный автомат	TEST-107	2024-01-01	rifle	107	t	5	250
107	Учебный автомат	TEST-109	2024-01-01	rifle	109	t	5	260
13	Учебный автомат	TEST-15	2024-01-01	rifle	15	t	5	270
17	Учебный автомат	TEST-19	2024-01-01	rifle	19	t	5	280
25	Учебный автомат	TEST-27	2024-01-01	rifle	27	t	5	290
2	Учебный автомат	TEST-3	2024-01-01	rifle	3	t	5	300
29	Учебный автомат	TEST-31	2024-01-01	rifle	31	t	5	310
37	Учебный автомат	TEST-39	2024-01-01	rifle	39	t	5	320
6	Учебный автомат	TEST-7	2024-01-01	rifle	7	t	5	330
91	Учебный автомат	TEST-93	2024-01-01	rifle	93	t	5	340
93	Учебный автомат	TEST-95	2024-01-01	rifle	95	t	5	350
95	Учебный автомат	TEST-97	2024-01-01	rifle	97	t	5	360
97	Учебный автомат	TEST-99	2024-01-01	rifle	99	t	5	370
31	Учебный пистолет	TEST-33	2024-01-01	pistol	33	t	6	10
84	Учебный автомат	TEST-86	2024-01-01	rifle	86	t	7	10
86	Учебный автомат	TEST-88	2024-01-01	rifle	88	t	8	10
30	Учебный автомат	TEST-32	2024-01-01	rifle	32	t	9	10
85	Учебный автомат	TEST-87	2024-01-01	rifle	87	t	10	10
87	Учебный автомат	TEST-89	2024-01-01	rifle	89	t	11	10
44	Учебный автомат	TEST-46	2024-01-01	rifle	46	t	12	10
62	Учебный автомат	TEST-64	2024-01-01	rifle	64	t	12	20
72	Учебный автомат	TEST-74	2024-01-01	rifle	74	t	12	30
88	Учебный автомат	TEST-90	2024-01-01	rifle	90	t	12	40
46	Учебный автомат	TEST-48	2024-01-01	rifle	48	t	13	10
64	Учебный автомат	TEST-66	2024-01-01	rifle	66	t	13	20
74	Учебный автомат	TEST-76	2024-01-01	rifle	76	t	13	30
90	Учебный автомат	TEST-92	2024-01-01	rifle	92	t	13	40
48	Учебный автомат	TEST-50	2024-01-01	rifle	50	t	14	10
66	Учебный автомат	TEST-68	2024-01-01	rifle	68	t	14	20
76	Учебный автомат	TEST-78	2024-01-01	rifle	78	t	14	30
78	Учебный автомат	TEST-80	2024-01-01	rifle	80	t	14	40
50	Учебный автомат	TEST-52	2024-01-01	rifle	52	t	15	10
68	Учебный автомат	TEST-70	2024-01-01	rifle	70	t	15	20
80	Учебный автомат	TEST-82	2024-01-01	rifle	82	t	15	30
11	Учебный автомат	TEST-13	2024-01-01	rifle	13	t	16	10
52	Учебный автомат	TEST-54	2024-01-01	rifle	54	t	16	20
82	Учебный автомат	TEST-84	2024-01-01	rifle	84	t	16	30
23	Учебный автомат	TEST-25	2024-01-01	rifle	25	t	17	10
4	Учебный автомат	TEST-5	2024-01-01	rifle	5	t	17	20
54	Учебный автомат	TEST-56	2024-01-01	rifle	56	t	17	30
15	Учебный автомат	TEST-17	2024-01-01	rifle	17	t	18	10
35	Учебный автомат	TEST-37	2024-01-01	rifle	37	t	18	20
56	Учебный автомат	TEST-58	2024-01-01	rifle	58	t	18	30
27	Учебный автомат	TEST-29	2024-01-01	rifle	29	t	19	10
40	Учебный автомат	TEST-42	2024-01-01	rifle	42	t	19	20
58	Учебный автомат	TEST-60	2024-01-01	rifle	60	t	19	30
42	Учебный автомат	TEST-44	2024-01-01	rifle	44	t	20	10
60	Учебный автомат	TEST-62	2024-01-01	rifle	62	t	20	20
70	Учебный автомат	TEST-72	2024-01-01	rifle	72	t	20	30
14	Учебный автомат	TEST-16	2024-01-01	rifle	16	t	21	10
45	Учебный автомат	TEST-47	2024-01-01	rifle	47	t	21	20
63	Учебный автомат	TEST-65	2024-01-01	rifle	65	t	21	30
89	Учебный автомат	TEST-91	2024-01-01	rifle	91	t	21	40
26	Учебный автомат	TEST-28	2024-01-01	rifle	28	t	22	10
47	Учебный автомат	TEST-49	2024-01-01	rifle	49	t	22	20
65	Учебный автомат	TEST-67	2024-01-01	rifle	67	t	22	30
77	Учебный автомат	TEST-79	2024-01-01	rifle	79	t	22	40
38	Учебный автомат	TEST-40	2024-01-01	rifle	40	t	23	10
49	Учебный автомат	TEST-51	2024-01-01	rifle	51	t	23	20
67	Учебный автомат	TEST-69	2024-01-01	rifle	69	t	23	30
79	Учебный автомат	TEST-81	2024-01-01	rifle	81	t	23	40
51	Учебный автомат	TEST-53	2024-01-01	rifle	53	t	24	10
69	Учебный автомат	TEST-71	2024-01-01	rifle	71	t	24	20
81	Учебный автомат	TEST-83	2024-01-01	rifle	83	t	24	30
22	Учебный автомат	TEST-24	2024-01-01	rifle	24	t	25	10
53	Учебный автомат	TEST-55	2024-01-01	rifle	55	t	25	20
83	Учебный автомат	TEST-85	2024-01-01	rifle	85	t	25	30
34	Учебный автомат	TEST-36	2024-01-01	rifle	36	t	26	10
55	Учебный автомат	TEST-57	2024-01-01	rifle	57	t	26	20
71	Учебный автомат	TEST-73	2024-01-01	rifle	73	t	26	30
39	Учебный автомат	TEST-41	2024-01-01	rifle	41	t	27	10
57	Учебный автомат	TEST-59	2024-01-01	rifle	59	t	27	20
73	Учебный автомат	TEST-75	2024-01-01	rifle	75	t	27	30
41	Учебный автомат	TEST-43	2024-01-01	rifle	43	t	28	10
59	Учебный автомат	TEST-61	2024-01-01	rifle	61	t	28	20
75	Учебный автомат	TEST-77	2024-01-01	rifle	77	t	28	30
3	Учебный автомат	TEST-4	2024-01-01	rifle	4	t	29	10
43	Учебный автомат	TEST-45	2024-01-01	rifle	45	t	29	20
61	Учебный автомат	TEST-63	2024-01-01	rifle	63	t	29	30
143	Учебный пистолет	TEST-145	2024-01-01	pistol	145	t	33	30
146	Учебный пистолет	TEST-148	2024-01-01	pistol	148	t	33	40
149	Учебный пистолет	TEST-151	2024-01-01	pistol	151	t	33	50
150	Учебный пистолет	TEST-152	2024-01-01	pistol	152	t	33	60
151	Учебный пистолет	TEST-153	2024-01-01	pistol	153	t	33	70
152	Учебный пистолет	TEST-154	2024-01-01	pistol	154	t	33	80
153	Учебный пистолет	TEST-155	2024-01-01	pistol	155	t	33	90
154	Учебный пистолет	TEST-156	2024-01-01	pistol	156	t	33	100
155	Учебный пистолет	TEST-157	2024-01-01	pistol	157	t	33	110
156	Учебный пистолет	TEST-158	2024-01-01	pistol	158	t	33	120
157	Учебный пистолет	TEST-159	2024-01-01	pistol	159	t	33	130
158	Учебный пистолет	TEST-160	2024-01-01	pistol	160	t	33	140
159	Учебный пистолет	TEST-161	2024-01-01	pistol	161	t	33	150
160	Учебный пистолет	TEST-162	2024-01-01	pistol	162	t	33	160
161	Учебный пистолет	TEST-163	2024-01-01	pistol	163	t	33	170
162	Учебный пистолет	TEST-164	2024-01-01	pistol	164	t	33	180
164	Учебный пистолет	TEST-166	2024-01-01	pistol	166	t	33	190
165	Учебный пистолет	TEST-167	2024-01-01	pistol	167	t	33	200
166	Учебный пистолет	TEST-168	2024-01-01	pistol	168	t	33	210
167	Учебный пистолет	TEST-169	2024-01-01	pistol	169	t	33	220
168	Учебный пистолет	TEST-170	2024-01-01	pistol	170	t	33	230
\.


--
-- Data for Name: schema_migrations; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.schema_migrations (name, checksum, applied_at) FROM stdin;
001_schema.sql	268c7b4d7f518884	2026-08-24 14:27:06.279681+07
002_reference_data.sql	1c433d59f9d5eda0	2026-08-24 14:27:06.283243+07
004_duty_type_names.sql	3928c1f76077be95	2026-08-24 14:31:07.475007+07
005_oo_start_time.sql	bcff66553005b373	2026-08-24 14:33:55.259045+07
006_seed_synthetic.sql	f4689328c03b20f6	2026-08-24 14:54:07.137431+07
007_duty_posts.sql	f2e673d5c52d235d	2026-08-24 15:32:26.1261+07
008_posts_reference.sql	c3e2a0db443af20e	2026-08-24 15:32:26.129087+07
009_seed_post_permits.sql	71465a05ee2ed319	2026-08-24 15:32:26.135418+07
010_post_names_fix.sql	69220083b03c5f67	2026-08-24 15:33:04.076167+07
011_calendar.sql	a2c8f6e07b17b3aa	2026-09-07 14:06:03.431417+07
012_seed_more_post_permits.sql	8fd91ecfa848a776	2026-09-07 14:16:51.353616+07
013_seed_personnel_expand.sql	f1bf4ad769837858	2026-09-07 14:37:09.148109+07
014_post_rank_ranges.sql	b0bee62e2378603c	2026-09-07 14:40:30.726159+07
015_seed_general_permits.sql	6864f67ad6e3fb94	2026-09-07 14:42:17.371118+07
016_widen_post_permits.sql	b993279f8878d5d2	2026-09-07 14:45:00.655918+07
017_senior_post_permits.sql	a5181fb7e3d1061a	2026-09-07 14:46:52.449533+07
018_operator_post_permits.sql	64b1c4ff1366f6ed	2026-09-07 14:47:53.58625+07
019_other_absence.sql	be8058be95d6a8d5	2026-09-07 15:09:06.563674+07
020_permit_valid_on.sql	32778e4372e79eb7	2026-09-07 16:13:57.785967+07
021_assignment_note.sql	8c4b2f9eeae8ed0e	2026-09-11 22:10:38.220024+07
022_shared_permits_weapons.sql	ee8abf4670dd11ba	2026-09-11 23:31:51.758064+07
023_historical_snapshots.sql	13da8466bdaadfc9	2026-09-11 23:31:51.793175+07
024_post_shifts.sql	a78aa1692a16f744	2026-09-13 10:40:56.212302+07
025_extend_permits_2027.sql	390fb6b3e9fd3b6f	2026-09-13 11:12:17.830107+07
026_pud_whole_shift.sql	71910675c286c810	2026-09-13 11:19:04.477482+07
027_auth_rbac.sql	358e062a387c942f	2026-09-13 12:05:25.864082+07
028_org_structure.sql	3accce516e1cfd3d	2026-09-13 12:58:06.823516+07
029_post_units.sql	2f219470ec3b751a	2026-09-19 14:13:43.111598+07
030_duty_queue.sql	100e3262b1e54c69	2026-09-19 14:40:58.204035+07
031_seed_unit_duty_mix.sql	99b0c6f3f6f5a772	2026-09-19 14:46:58.341842+07
032_seed_company_permits.sql	a4b0350bd2992ec7	2026-09-19 14:47:34.92622+07
033_queue_defaults.sql	535027960717033e	2026-09-19 14:48:35.540244+07
034_queue_min_days_off.sql	e55dac6bdc1f0469	2026-09-19 15:01:09.869389+07
035_muster.sql	594ee6802b514d6a	2026-09-20 14:18:17.972434+07
036_unit_names.sql	9db44f129bafd927	2026-09-20 15:05:39.186343+07
037_post_unit_from_queue.sql	c63a189f35138ac3	2026-09-20 15:42:27.20779+07
038_duty_type_settings.sql	b061fdc6a669ffce	2026-09-20 15:58:15.680068+07
039_allow_consecutive_rest.sql	480191b51a1b1c73	2026-09-20 16:04:03.498737+07
040_keep_rest_on_consecutive.sql	24901036432f6645	2026-09-20 16:05:51.860959+07
041_post_employees.sql	3787f6d386a7120c	2026-09-20 19:10:08.799417+07
042_duty_type_schedule_rules.sql	ee4f3d0dc580e27a	2026-09-20 19:19:50.921698+07
043_permit_orders.sql	9b187b594015fc32	2026-09-20 19:49:24.095961+07
044_drop_duty_responsibilities.sql	ce16aed5322299bf	2026-09-26 16:49:34.989492+07
045_duty_type_order.sql	1cc3936778899f6a	2026-09-26 17:23:01.151124+07
046_weapon_by_assignment.sql	a82d5cd402300254	2026-09-26 17:41:56.095965+07
047_order_templates.sql	153c2e80f0a8bf27	2026-09-27 13:13:31.834104+07
048_order_template_versions.sql	12f5a338094d3f93	2026-09-27 13:15:40.788371+07
049_staff_positions.sql	7e4745f2ce817ff7	2026-09-27 13:37:27.802592+07
050_squad_staff.sql	97deb916f58c0160	2026-09-27 13:59:22.24411+07
051_unplaced_without_unit.sql	c34076bad427af57	2026-09-27 14:29:17.483089+07
052_commander_by_title.sql	df39a4a0b930911a	2026-09-27 14:36:10.921284+07
053_acting_and_headquarters.sql	cbab3cc56848f84a	2026-09-27 14:49:18.755948+07
054_weapons_by_units.sql	700c085faabe54fb	2026-09-27 15:06:03.804977+07
055_employee_exclusion.sql	ffaa13415cba40e2	2026-09-27 16:06:04.99205+07
056_audit_changes.sql	ba98ed95cfb8e72d	2026-09-27 16:52:19.026529+07
057_audit_skip_login_noise.sql	8db3873b29e71872	2026-09-27 16:55:55.416655+07
058_orders_registry.sql	f9d90c21fa80e025	2026-09-27 17:04:02.7493+07
059_order_parsing.sql	6225d39912c39058	2026-09-27 19:09:43.766361+07
060_parse_sections.sql	94fad396ec47c0fa	2026-09-27 19:25:49.079698+07
061_parse_profiles.sql	07d843ae64b6a192	2026-09-27 19:32:27.293257+07
062_access_holes.sql	c7c9b2c096b396c9	2026-09-27 19:53:17.094418+07
063_queue_settings_text.sql	6bcc635253a17c2c	2026-09-27 20:07:37.992766+07
\.


--
-- Name: change_log_id_seq; Type: SEQUENCE SET; Schema: audit; Owner: -
--

SELECT pg_catalog.setval('audit.change_log_id_seq', 1, false);


--
-- Name: changes_id_seq; Type: SEQUENCE SET; Schema: audit; Owner: -
--

SELECT pg_catalog.setval('audit.changes_id_seq', 54, true);


--
-- Name: acting_commanders_id_seq; Type: SEQUENCE SET; Schema: core; Owner: -
--

SELECT pg_catalog.setval('core.acting_commanders_id_seq', 1, false);


--
-- Name: positions_id_seq; Type: SEQUENCE SET; Schema: core; Owner: -
--

SELECT pg_catalog.setval('core.positions_id_seq', 322, true);


--
-- Name: ranks_id_seq; Type: SEQUENCE SET; Schema: core; Owner: -
--

SELECT pg_catalog.setval('core.ranks_id_seq', 15, true);


--
-- Name: security_events_id_seq; Type: SEQUENCE SET; Schema: core; Owner: -
--

SELECT pg_catalog.setval('core.security_events_id_seq', 464, true);


--
-- Name: units_id_seq; Type: SEQUENCE SET; Schema: core; Owner: -
--

SELECT pg_catalog.setval('core.units_id_seq', 50, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: core; Owner: -
--

SELECT pg_catalog.setval('core.users_id_seq', 195, true);


--
-- Name: duties_id_seq; Type: SEQUENCE SET; Schema: duty; Owner: -
--

SELECT pg_catalog.setval('duty.duties_id_seq', 1644, true);


--
-- Name: duty_assignments_id_seq; Type: SEQUENCE SET; Schema: duty; Owner: -
--

SELECT pg_catalog.setval('duty.duty_assignments_id_seq', 17318, true);


--
-- Name: duty_posts_id_seq; Type: SEQUENCE SET; Schema: duty; Owner: -
--

SELECT pg_catalog.setval('duty.duty_posts_id_seq', 35, true);


--
-- Name: duty_type_schedules_id_seq; Type: SEQUENCE SET; Schema: duty; Owner: -
--

SELECT pg_catalog.setval('duty.duty_type_schedules_id_seq', 5, true);


--
-- Name: duty_types_id_seq; Type: SEQUENCE SET; Schema: duty; Owner: -
--

SELECT pg_catalog.setval('duty.duty_types_id_seq', 9, true);


--
-- Name: order_template_versions_id_seq; Type: SEQUENCE SET; Schema: duty; Owner: -
--

SELECT pg_catalog.setval('duty.order_template_versions_id_seq', 5, true);


--
-- Name: phrases_id_seq; Type: SEQUENCE SET; Schema: parse; Owner: -
--

SELECT pg_catalog.setval('parse.phrases_id_seq', 23, true);


--
-- Name: profiles_id_seq; Type: SEQUENCE SET; Schema: parse; Owner: -
--

SELECT pg_catalog.setval('parse.profiles_id_seq', 1, false);


--
-- Name: sections_id_seq; Type: SEQUENCE SET; Schema: parse; Owner: -
--

SELECT pg_catalog.setval('parse.sections_id_seq', 5, true);


--
-- Name: absence_types_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.absence_types_id_seq', 5, true);


--
-- Name: absences_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.absences_id_seq', 12, true);


--
-- Name: employee_permits_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.employee_permits_id_seq', 1923, true);


--
-- Name: employees_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.employees_id_seq', 174, true);


--
-- Name: permit_directions_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.permit_directions_id_seq', 5, true);


--
-- Name: permit_orders_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.permit_orders_id_seq', 14, true);


--
-- Name: permit_types_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.permit_types_id_seq', 26, true);


--
-- Name: weapon_reservations_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.weapon_reservations_id_seq', 1, false);


--
-- Name: weapons_id_seq; Type: SEQUENCE SET; Schema: personnel; Owner: -
--

SELECT pg_catalog.setval('personnel.weapons_id_seq', 193, true);


--
-- Name: change_log change_log_pkey; Type: CONSTRAINT; Schema: audit; Owner: -
--

ALTER TABLE ONLY audit.change_log
    ADD CONSTRAINT change_log_pkey PRIMARY KEY (id);


--
-- Name: changes changes_pkey; Type: CONSTRAINT; Schema: audit; Owner: -
--

ALTER TABLE ONLY audit.changes
    ADD CONSTRAINT changes_pkey PRIMARY KEY (id);


--
-- Name: acting_commanders acting_commanders_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.acting_commanders
    ADD CONSTRAINT acting_commanders_pkey PRIMARY KEY (id);


--
-- Name: calendar_days calendar_days_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.calendar_days
    ADD CONSTRAINT calendar_days_pkey PRIMARY KEY (day);


--
-- Name: login_failures login_failures_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.login_failures
    ADD CONSTRAINT login_failures_pkey PRIMARY KEY (user_id, ip);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (code);


--
-- Name: positions positions_employee_id_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.positions
    ADD CONSTRAINT positions_employee_id_key UNIQUE (employee_id);


--
-- Name: positions positions_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.positions
    ADD CONSTRAINT positions_pkey PRIMARY KEY (id);


--
-- Name: ranks ranks_name_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.ranks
    ADD CONSTRAINT ranks_name_key UNIQUE (name);


--
-- Name: ranks ranks_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.ranks
    ADD CONSTRAINT ranks_pkey PRIMARY KEY (id);


--
-- Name: ranks ranks_seniority_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.ranks
    ADD CONSTRAINT ranks_seniority_key UNIQUE (seniority);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_code, permission_code);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (code);


--
-- Name: security_events security_events_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.security_events
    ADD CONSTRAINT security_events_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (key);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: user_permissions user_permissions_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_permissions
    ADD CONSTRAINT user_permissions_pkey PRIMARY KEY (user_id, permission_code);


--
-- Name: users users_employee_id_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_employee_id_key UNIQUE (employee_id);


--
-- Name: users users_login_key; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_login_key UNIQUE (login);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: duties duties_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties
    ADD CONSTRAINT duties_pkey PRIMARY KEY (id);


--
-- Name: duty_assignments duty_assignments_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_pkey PRIMARY KEY (id);


--
-- Name: duty_posts duty_posts_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_posts
    ADD CONSTRAINT duty_posts_pkey PRIMARY KEY (id);


--
-- Name: duty_type_permits duty_type_permits_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_type_permits
    ADD CONSTRAINT duty_type_permits_pkey PRIMARY KEY (duty_type_id, permit_type_id);


--
-- Name: duty_type_schedules duty_type_schedules_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_type_schedules
    ADD CONSTRAINT duty_type_schedules_pkey PRIMARY KEY (id);


--
-- Name: duty_types duty_types_code_key; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_types
    ADD CONSTRAINT duty_types_code_key UNIQUE (code);


--
-- Name: duty_types duty_types_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_types
    ADD CONSTRAINT duty_types_pkey PRIMARY KEY (id);


--
-- Name: order_template_versions order_template_versions_duty_type_id_version_key; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.order_template_versions
    ADD CONSTRAINT order_template_versions_duty_type_id_version_key UNIQUE (duty_type_id, version);


--
-- Name: order_template_versions order_template_versions_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.order_template_versions
    ADD CONSTRAINT order_template_versions_pkey PRIMARY KEY (id);


--
-- Name: post_employees post_employees_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_employees
    ADD CONSTRAINT post_employees_pkey PRIMARY KEY (post_id, employee_id);


--
-- Name: post_rank_weights post_rank_weights_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_rank_weights
    ADD CONSTRAINT post_rank_weights_pkey PRIMARY KEY (post_id, rank_id);


--
-- Name: post_responsibilities post_responsibilities_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_responsibilities
    ADD CONSTRAINT post_responsibilities_pkey PRIMARY KEY (post_id, on_date);


--
-- Name: post_units post_units_pkey; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_units
    ADD CONSTRAINT post_units_pkey PRIMARY KEY (post_id, turn);


--
-- Name: post_units post_units_post_id_unit_id_key; Type: CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_units
    ADD CONSTRAINT post_units_post_id_unit_id_key UNIQUE (post_id, unit_id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (order_id);


--
-- Name: phrases phrases_kind_target_phrase_key; Type: CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.phrases
    ADD CONSTRAINT phrases_kind_target_phrase_key UNIQUE (kind, target, phrase);


--
-- Name: phrases phrases_pkey; Type: CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.phrases
    ADD CONSTRAINT phrases_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: sections sections_pkey; Type: CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.sections
    ADD CONSTRAINT sections_pkey PRIMARY KEY (id);


--
-- Name: absence_types absence_types_code_key; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absence_types
    ADD CONSTRAINT absence_types_code_key UNIQUE (code);


--
-- Name: absence_types absence_types_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absence_types
    ADD CONSTRAINT absence_types_pkey PRIMARY KEY (id);


--
-- Name: absences absences_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences
    ADD CONSTRAINT absences_pkey PRIMARY KEY (id);


--
-- Name: employee_permits employee_permits_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_permits
    ADD CONSTRAINT employee_permits_pkey PRIMARY KEY (id);


--
-- Name: employee_post_weights employee_post_weights_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_post_weights
    ADD CONSTRAINT employee_post_weights_pkey PRIMARY KEY (employee_id, post_id);


--
-- Name: employees employees_personnel_number_key; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employees
    ADD CONSTRAINT employees_personnel_number_key UNIQUE (personnel_number);


--
-- Name: employees employees_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employees
    ADD CONSTRAINT employees_pkey PRIMARY KEY (id);


--
-- Name: permit_directions permit_directions_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_directions
    ADD CONSTRAINT permit_directions_pkey PRIMARY KEY (id);


--
-- Name: permit_orders permit_orders_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_orders
    ADD CONSTRAINT permit_orders_pkey PRIMARY KEY (id);


--
-- Name: permit_types permit_types_code_key; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_types
    ADD CONSTRAINT permit_types_code_key UNIQUE (code);


--
-- Name: permit_types permit_types_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_types
    ADD CONSTRAINT permit_types_pkey PRIMARY KEY (id);


--
-- Name: weapon_reservations weapon_reservations_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapon_reservations
    ADD CONSTRAINT weapon_reservations_pkey PRIMARY KEY (id);


--
-- Name: weapons weapons_pkey; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapons
    ADD CONSTRAINT weapons_pkey PRIMARY KEY (id);


--
-- Name: weapons weapons_serial_number_key; Type: CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapons
    ADD CONSTRAINT weapons_serial_number_key UNIQUE (serial_number);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (name);


--
-- Name: changes_changed_at_idx; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX changes_changed_at_idx ON audit.changes USING btree (changed_at DESC);


--
-- Name: changes_coalesce_idx; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX changes_coalesce_idx ON audit.changes USING btree (COALESCE((new_data ->> 'employee_id'::text), (old_data ->> 'employee_id'::text)));


--
-- Name: changes_table_name_row_id_idx; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX changes_table_name_row_id_idx ON audit.changes USING btree (table_name, row_id);


--
-- Name: changes_user_id_idx; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX changes_user_id_idx ON audit.changes USING btree (user_id);


--
-- Name: idx_audit_record; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX idx_audit_record ON audit.change_log USING btree (schema_name, table_name, record_id);


--
-- Name: idx_audit_time; Type: INDEX; Schema: audit; Owner: -
--

CREATE INDEX idx_audit_time ON audit.change_log USING btree (changed_at DESC);


--
-- Name: acting_commanders_employee_id_idx; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX acting_commanders_employee_id_idx ON core.acting_commanders USING btree (employee_id) WHERE (cancelled_at IS NULL);


--
-- Name: acting_commanders_unit_id_date_from_date_to_idx; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX acting_commanders_unit_id_date_from_date_to_idx ON core.acting_commanders USING btree (unit_id, date_from, date_to) WHERE (cancelled_at IS NULL);


--
-- Name: idx_security_events_at; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_security_events_at ON core.security_events USING btree (at DESC);


--
-- Name: idx_sessions_expires; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_sessions_expires ON core.sessions USING btree (expires_at);


--
-- Name: idx_sessions_user; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_sessions_user ON core.sessions USING btree (user_id);


--
-- Name: idx_units_parent; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX idx_units_parent ON core.units USING btree (parent_id);


--
-- Name: positions_one_commander; Type: INDEX; Schema: core; Owner: -
--

CREATE UNIQUE INDEX positions_one_commander ON core.positions USING btree (unit_id) WHERE is_commander;


--
-- Name: positions_unit_id_sort_order_idx; Type: INDEX; Schema: core; Owner: -
--

CREATE INDEX positions_unit_id_sort_order_idx ON core.positions USING btree (unit_id, sort_order);


--
-- Name: units_one_headquarters; Type: INDEX; Schema: core; Owner: -
--

CREATE UNIQUE INDEX units_one_headquarters ON core.units USING btree ((true)) WHERE is_headquarters;


--
-- Name: duties_one_per_day; Type: INDEX; Schema: duty; Owner: -
--

CREATE UNIQUE INDEX duties_one_per_day ON duty.duties USING btree (duty_type_id, start_date) WHERE (status <> 'cancelled'::text);


--
-- Name: duty_assignments_weapon_id_idx; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX duty_assignments_weapon_id_idx ON duty.duty_assignments USING btree (weapon_id) WHERE (weapon_id IS NOT NULL);


--
-- Name: idx_assignments_duty; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_assignments_duty ON duty.duty_assignments USING btree (duty_id);


--
-- Name: idx_assignments_employee; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_assignments_employee ON duty.duty_assignments USING btree (employee_id);


--
-- Name: idx_assignments_post; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_assignments_post ON duty.duty_assignments USING btree (post_id);


--
-- Name: idx_duties_period; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_duties_period ON duty.duties USING btree (starts_at, ends_at);


--
-- Name: idx_duties_type; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_duties_type ON duty.duties USING btree (duty_type_id);


--
-- Name: idx_duties_unit; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_duties_unit ON duty.duties USING btree (unit_id);


--
-- Name: idx_post_employees_employee; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_post_employees_employee ON duty.post_employees USING btree (employee_id);


--
-- Name: idx_post_responsibilities_unit; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_post_responsibilities_unit ON duty.post_responsibilities USING btree (unit_id);


--
-- Name: idx_posts_duty_type; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_posts_duty_type ON duty.duty_posts USING btree (duty_type_id);


--
-- Name: idx_posts_unit; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_posts_unit ON duty.duty_posts USING btree (unit_id);


--
-- Name: idx_schedules_duty_type; Type: INDEX; Schema: duty; Owner: -
--

CREATE INDEX idx_schedules_duty_type ON duty.duty_type_schedules USING btree (duty_type_id);


--
-- Name: uq_assignment_employee; Type: INDEX; Schema: duty; Owner: -
--

CREATE UNIQUE INDEX uq_assignment_employee ON duty.duty_assignments USING btree (duty_id, employee_id, COALESCE(on_date, '-infinity'::date));


--
-- Name: uq_assignment_post; Type: INDEX; Schema: duty; Owner: -
--

CREATE UNIQUE INDEX uq_assignment_post ON duty.duty_assignments USING btree (duty_id, post_id, COALESCE(on_date, '-infinity'::date));


--
-- Name: uq_posts_name; Type: INDEX; Schema: duty; Owner: -
--

CREATE UNIQUE INDEX uq_posts_name ON duty.duty_posts USING btree (duty_type_id, COALESCE(unit_id, 0), name);


--
-- Name: absences_order_id_idx; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX absences_order_id_idx ON personnel.absences USING btree (order_id) WHERE (order_id IS NOT NULL);


--
-- Name: idx_absences_active; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_absences_active ON personnel.absences USING btree (employee_id, date_from, date_to) WHERE (cancelled_at IS NULL);


--
-- Name: idx_absences_employee; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_absences_employee ON personnel.absences USING btree (employee_id);


--
-- Name: idx_absences_period; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_absences_period ON personnel.absences USING btree (date_from, date_to);


--
-- Name: idx_employees_active; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_employees_active ON personnel.employees USING btree (is_active) WHERE is_active;


--
-- Name: idx_employees_fio; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_employees_fio ON personnel.employees USING btree (last_name, first_name, middle_name);


--
-- Name: idx_employees_unit; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_employees_unit ON personnel.employees USING btree (unit_id);


--
-- Name: idx_permit_directions_parent; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permit_directions_parent ON personnel.permit_directions USING btree (parent_id);


--
-- Name: idx_permit_orders_direction; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permit_orders_direction ON personnel.permit_orders USING btree (direction_id, issued_on DESC);


--
-- Name: idx_permits_employee; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permits_employee ON personnel.employee_permits USING btree (employee_id);


--
-- Name: idx_permits_expiry; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permits_expiry ON personnel.employee_permits USING btree (expires_at) WHERE (status = 'active'::text);


--
-- Name: idx_permits_lookup; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permits_lookup ON personnel.employee_permits USING btree (employee_id, permit_type_id, post_id);


--
-- Name: idx_permits_order; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permits_order ON personnel.employee_permits USING btree (order_id);


--
-- Name: idx_permits_post; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX idx_permits_post ON personnel.employee_permits USING btree (post_id);


--
-- Name: uq_permit_orders; Type: INDEX; Schema: personnel; Owner: -
--

CREATE UNIQUE INDEX uq_permit_orders ON personnel.permit_orders USING btree (number, issued_on);


--
-- Name: weapon_reservations_weapon_id_date_from_date_to_idx; Type: INDEX; Schema: personnel; Owner: -
--

CREATE INDEX weapon_reservations_weapon_id_date_from_date_to_idx ON personnel.weapon_reservations USING btree (weapon_id, date_from, date_to) WHERE (cancelled_at IS NULL);


--
-- Name: changes changes_immutable; Type: TRIGGER; Schema: audit; Owner: -
--

CREATE TRIGGER changes_immutable BEFORE DELETE OR UPDATE ON audit.changes FOR EACH ROW EXECUTE FUNCTION audit.forbid_change();


--
-- Name: changes changes_no_truncate; Type: TRIGGER; Schema: audit; Owner: -
--

CREATE TRIGGER changes_no_truncate BEFORE TRUNCATE ON audit.changes FOR EACH STATEMENT EXECUTE FUNCTION audit.forbid_change();


--
-- Name: acting_commanders audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.acting_commanders FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: calendar_days audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.calendar_days FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: positions audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.positions FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: ranks audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.ranks FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: role_permissions audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.role_permissions FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: roles audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.roles FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: settings audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.settings FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: units audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.units FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: user_permissions audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.user_permissions FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: users audit_changes; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON core.users FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: calendar_days trg_calendar_touch; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER trg_calendar_touch BEFORE UPDATE ON core.calendar_days FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: units trg_units_touch; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER trg_units_touch BEFORE UPDATE ON core.units FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: users trg_users_touch; Type: TRIGGER; Schema: core; Owner: -
--

CREATE TRIGGER trg_users_touch BEFORE UPDATE ON core.users FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: duties audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.duties FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: duty_assignments audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.duty_assignments FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: duty_posts audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.duty_posts FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: duty_type_permits audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.duty_type_permits FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: duty_type_schedules audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.duty_type_schedules FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: duty_types audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.duty_types FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: order_template_versions audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.order_template_versions FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: post_employees audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.post_employees FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: post_rank_weights audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.post_rank_weights FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: post_responsibilities audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.post_responsibilities FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: post_units audit_changes; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON duty.post_units FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: duties duties_start_date; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER duties_start_date BEFORE INSERT OR UPDATE OF starts_at ON duty.duties FOR EACH ROW EXECUTE FUNCTION duty.set_start_date();


--
-- Name: duties trg_duties_touch; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER trg_duties_touch BEFORE UPDATE ON duty.duties FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: duty_posts trg_posts_touch; Type: TRIGGER; Schema: duty; Owner: -
--

CREATE TRIGGER trg_posts_touch BEFORE UPDATE ON duty.duty_posts FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: phrases audit_changes; Type: TRIGGER; Schema: parse; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON parse.phrases FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: profiles audit_changes; Type: TRIGGER; Schema: parse; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON parse.profiles FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: sections audit_changes; Type: TRIGGER; Schema: parse; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON parse.sections FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: absence_types audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.absence_types FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: absences audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.absences FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: employee_permits audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.employee_permits FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: employee_post_weights audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.employee_post_weights FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: employees audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.employees FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: permit_directions audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.permit_directions FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: permit_orders audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.permit_orders FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: permit_types audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.permit_types FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: weapon_reservations audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.weapon_reservations FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: weapons audit_changes; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER audit_changes AFTER INSERT OR DELETE OR UPDATE ON personnel.weapons FOR EACH ROW EXECUTE FUNCTION audit.log_change();


--
-- Name: absences trg_absences_touch; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER trg_absences_touch BEFORE UPDATE ON personnel.absences FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: employees trg_employees_touch; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER trg_employees_touch BEFORE UPDATE ON personnel.employees FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: permit_orders trg_permit_orders_touch; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER trg_permit_orders_touch BEFORE UPDATE ON personnel.permit_orders FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: employee_permits trg_permits_check_post; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER trg_permits_check_post BEFORE INSERT OR UPDATE ON personnel.employee_permits FOR EACH ROW EXECUTE FUNCTION personnel.check_permit_post();


--
-- Name: employee_permits trg_permits_touch; Type: TRIGGER; Schema: personnel; Owner: -
--

CREATE TRIGGER trg_permits_touch BEFORE UPDATE ON personnel.employee_permits FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();


--
-- Name: change_log change_log_changed_by_fkey; Type: FK CONSTRAINT; Schema: audit; Owner: -
--

ALTER TABLE ONLY audit.change_log
    ADD CONSTRAINT change_log_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: acting_commanders acting_commanders_created_by_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.acting_commanders
    ADD CONSTRAINT acting_commanders_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id);


--
-- Name: acting_commanders acting_commanders_employee_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.acting_commanders
    ADD CONSTRAINT acting_commanders_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id);


--
-- Name: acting_commanders acting_commanders_unit_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.acting_commanders
    ADD CONSTRAINT acting_commanders_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE CASCADE;


--
-- Name: login_failures login_failures_user_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.login_failures
    ADD CONSTRAINT login_failures_user_id_fkey FOREIGN KEY (user_id) REFERENCES core.users(id) ON DELETE CASCADE;


--
-- Name: positions positions_employee_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.positions
    ADD CONSTRAINT positions_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE SET NULL;


--
-- Name: positions positions_unit_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.positions
    ADD CONSTRAINT positions_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_permission_code_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.role_permissions
    ADD CONSTRAINT role_permissions_permission_code_fkey FOREIGN KEY (permission_code) REFERENCES core.permissions(code) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_code_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.role_permissions
    ADD CONSTRAINT role_permissions_role_code_fkey FOREIGN KEY (role_code) REFERENCES core.roles(code) ON DELETE CASCADE;


--
-- Name: security_events security_events_actor_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.security_events
    ADD CONSTRAINT security_events_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: security_events security_events_user_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.security_events
    ADD CONSTRAINT security_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES core.users(id) ON DELETE CASCADE;


--
-- Name: settings settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.settings
    ADD CONSTRAINT settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: units units_commander_employee_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.units
    ADD CONSTRAINT units_commander_employee_id_fkey FOREIGN KEY (commander_employee_id) REFERENCES personnel.employees(id) ON DELETE SET NULL;


--
-- Name: units units_parent_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.units
    ADD CONSTRAINT units_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: user_permissions user_permissions_granted_by_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_permissions
    ADD CONSTRAINT user_permissions_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: user_permissions user_permissions_permission_code_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_permissions
    ADD CONSTRAINT user_permissions_permission_code_fkey FOREIGN KEY (permission_code) REFERENCES core.permissions(code) ON DELETE CASCADE;


--
-- Name: user_permissions user_permissions_user_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.user_permissions
    ADD CONSTRAINT user_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES core.users(id) ON DELETE CASCADE;


--
-- Name: users users_created_by_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: users users_employee_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE RESTRICT;


--
-- Name: users users_role_known; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_role_known FOREIGN KEY (role_code) REFERENCES core.roles(code);


--
-- Name: users users_scope_unit_id_fkey; Type: FK CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.users
    ADD CONSTRAINT users_scope_unit_id_fkey FOREIGN KEY (scope_unit_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: duties duties_approved_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties
    ADD CONSTRAINT duties_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: duties duties_created_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties
    ADD CONSTRAINT duties_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: duties duties_duty_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties
    ADD CONSTRAINT duties_duty_type_id_fkey FOREIGN KEY (duty_type_id) REFERENCES duty.duty_types(id) ON DELETE RESTRICT;


--
-- Name: duties duties_unapproved_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties
    ADD CONSTRAINT duties_unapproved_by_fkey FOREIGN KEY (unapproved_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: duties duties_unit_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duties
    ADD CONSTRAINT duties_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: duty_assignments duty_assignments_duty_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_duty_id_fkey FOREIGN KEY (duty_id) REFERENCES duty.duties(id) ON DELETE CASCADE;


--
-- Name: duty_assignments duty_assignments_employee_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE RESTRICT;


--
-- Name: duty_assignments duty_assignments_noted_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_noted_by_fkey FOREIGN KEY (noted_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: duty_assignments duty_assignments_override_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_override_by_fkey FOREIGN KEY (override_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: duty_assignments duty_assignments_post_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE RESTRICT;


--
-- Name: duty_assignments duty_assignments_weapon_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_assignments
    ADD CONSTRAINT duty_assignments_weapon_id_fkey FOREIGN KEY (weapon_id) REFERENCES personnel.weapons(id);


--
-- Name: duty_posts duty_posts_duty_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_posts
    ADD CONSTRAINT duty_posts_duty_type_id_fkey FOREIGN KEY (duty_type_id) REFERENCES duty.duty_types(id) ON DELETE RESTRICT;


--
-- Name: duty_posts duty_posts_required_permit_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_posts
    ADD CONSTRAINT duty_posts_required_permit_type_id_fkey FOREIGN KEY (required_permit_type_id) REFERENCES personnel.permit_types(id);


--
-- Name: duty_posts duty_posts_unit_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_posts
    ADD CONSTRAINT duty_posts_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: duty_type_permits duty_type_permits_duty_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_type_permits
    ADD CONSTRAINT duty_type_permits_duty_type_id_fkey FOREIGN KEY (duty_type_id) REFERENCES duty.duty_types(id) ON DELETE CASCADE;


--
-- Name: duty_type_permits duty_type_permits_permit_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_type_permits
    ADD CONSTRAINT duty_type_permits_permit_type_id_fkey FOREIGN KEY (permit_type_id) REFERENCES personnel.permit_types(id) ON DELETE RESTRICT;


--
-- Name: duty_type_schedules duty_type_schedules_duty_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.duty_type_schedules
    ADD CONSTRAINT duty_type_schedules_duty_type_id_fkey FOREIGN KEY (duty_type_id) REFERENCES duty.duty_types(id) ON DELETE CASCADE;


--
-- Name: order_template_versions order_template_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.order_template_versions
    ADD CONSTRAINT order_template_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id);


--
-- Name: order_template_versions order_template_versions_duty_type_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.order_template_versions
    ADD CONSTRAINT order_template_versions_duty_type_id_fkey FOREIGN KEY (duty_type_id) REFERENCES duty.duty_types(id) ON DELETE CASCADE;


--
-- Name: post_employees post_employees_created_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_employees
    ADD CONSTRAINT post_employees_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: post_employees post_employees_employee_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_employees
    ADD CONSTRAINT post_employees_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE CASCADE;


--
-- Name: post_employees post_employees_post_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_employees
    ADD CONSTRAINT post_employees_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE CASCADE;


--
-- Name: post_rank_weights post_rank_weights_post_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_rank_weights
    ADD CONSTRAINT post_rank_weights_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE CASCADE;


--
-- Name: post_rank_weights post_rank_weights_rank_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_rank_weights
    ADD CONSTRAINT post_rank_weights_rank_id_fkey FOREIGN KEY (rank_id) REFERENCES core.ranks(id) ON DELETE CASCADE;


--
-- Name: post_responsibilities post_responsibilities_assigned_by_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_responsibilities
    ADD CONSTRAINT post_responsibilities_assigned_by_fkey FOREIGN KEY (assigned_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: post_responsibilities post_responsibilities_post_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_responsibilities
    ADD CONSTRAINT post_responsibilities_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE CASCADE;


--
-- Name: post_responsibilities post_responsibilities_unit_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_responsibilities
    ADD CONSTRAINT post_responsibilities_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: post_units post_units_post_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_units
    ADD CONSTRAINT post_units_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE CASCADE;


--
-- Name: post_units post_units_unit_id_fkey; Type: FK CONSTRAINT; Schema: duty; Owner: -
--

ALTER TABLE ONLY duty.post_units
    ADD CONSTRAINT post_units_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: documents documents_order_id_fkey; Type: FK CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.documents
    ADD CONSTRAINT documents_order_id_fkey FOREIGN KEY (order_id) REFERENCES personnel.permit_orders(id) ON DELETE CASCADE;


--
-- Name: phrases phrases_created_by_fkey; Type: FK CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.phrases
    ADD CONSTRAINT phrases_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id);


--
-- Name: phrases phrases_section_id_fkey; Type: FK CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.phrases
    ADD CONSTRAINT phrases_section_id_fkey FOREIGN KEY (section_id) REFERENCES parse.sections(id);


--
-- Name: profiles profiles_created_by_fkey; Type: FK CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.profiles
    ADD CONSTRAINT profiles_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id);


--
-- Name: profiles profiles_permit_type_id_fkey; Type: FK CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.profiles
    ADD CONSTRAINT profiles_permit_type_id_fkey FOREIGN KEY (permit_type_id) REFERENCES personnel.permit_types(id);


--
-- Name: sections sections_created_by_fkey; Type: FK CONSTRAINT; Schema: parse; Owner: -
--

ALTER TABLE ONLY parse.sections
    ADD CONSTRAINT sections_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id);


--
-- Name: absences absences_absence_type_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences
    ADD CONSTRAINT absences_absence_type_id_fkey FOREIGN KEY (absence_type_id) REFERENCES personnel.absence_types(id) ON DELETE RESTRICT;


--
-- Name: absences absences_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences
    ADD CONSTRAINT absences_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: absences absences_created_by_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences
    ADD CONSTRAINT absences_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: absences absences_employee_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences
    ADD CONSTRAINT absences_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE CASCADE;


--
-- Name: absences absences_order_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.absences
    ADD CONSTRAINT absences_order_id_fkey FOREIGN KEY (order_id) REFERENCES personnel.permit_orders(id) ON DELETE SET NULL;


--
-- Name: employee_permits employee_permits_employee_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_permits
    ADD CONSTRAINT employee_permits_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE CASCADE;


--
-- Name: employee_permits employee_permits_order_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_permits
    ADD CONSTRAINT employee_permits_order_id_fkey FOREIGN KEY (order_id) REFERENCES personnel.permit_orders(id) ON DELETE SET NULL;


--
-- Name: employee_permits employee_permits_permit_type_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_permits
    ADD CONSTRAINT employee_permits_permit_type_id_fkey FOREIGN KEY (permit_type_id) REFERENCES personnel.permit_types(id) ON DELETE RESTRICT;


--
-- Name: employee_permits employee_permits_post_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_permits
    ADD CONSTRAINT employee_permits_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE RESTRICT;


--
-- Name: employee_post_weights employee_post_weights_employee_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_post_weights
    ADD CONSTRAINT employee_post_weights_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id) ON DELETE CASCADE;


--
-- Name: employee_post_weights employee_post_weights_post_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_post_weights
    ADD CONSTRAINT employee_post_weights_post_id_fkey FOREIGN KEY (post_id) REFERENCES duty.duty_posts(id) ON DELETE CASCADE;


--
-- Name: employee_post_weights employee_post_weights_updated_by_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employee_post_weights
    ADD CONSTRAINT employee_post_weights_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: employees employees_rank_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employees
    ADD CONSTRAINT employees_rank_id_fkey FOREIGN KEY (rank_id) REFERENCES core.ranks(id) ON DELETE RESTRICT;


--
-- Name: employees employees_unit_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.employees
    ADD CONSTRAINT employees_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE RESTRICT;


--
-- Name: permit_directions permit_directions_parent_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_directions
    ADD CONSTRAINT permit_directions_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES personnel.permit_directions(id) ON DELETE RESTRICT;


--
-- Name: permit_orders permit_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_orders
    ADD CONSTRAINT permit_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id) ON DELETE SET NULL;


--
-- Name: permit_orders permit_orders_direction_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_orders
    ADD CONSTRAINT permit_orders_direction_id_fkey FOREIGN KEY (direction_id) REFERENCES personnel.permit_directions(id) ON DELETE RESTRICT;


--
-- Name: permit_orders permit_orders_profile_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.permit_orders
    ADD CONSTRAINT permit_orders_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES parse.profiles(id);


--
-- Name: weapon_reservations weapon_reservations_created_by_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapon_reservations
    ADD CONSTRAINT weapon_reservations_created_by_fkey FOREIGN KEY (created_by) REFERENCES core.users(id);


--
-- Name: weapon_reservations weapon_reservations_employee_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapon_reservations
    ADD CONSTRAINT weapon_reservations_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES personnel.employees(id);


--
-- Name: weapon_reservations weapon_reservations_order_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapon_reservations
    ADD CONSTRAINT weapon_reservations_order_id_fkey FOREIGN KEY (order_id) REFERENCES personnel.permit_orders(id) ON DELETE SET NULL;


--
-- Name: weapon_reservations weapon_reservations_weapon_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapon_reservations
    ADD CONSTRAINT weapon_reservations_weapon_id_fkey FOREIGN KEY (weapon_id) REFERENCES personnel.weapons(id);


--
-- Name: weapons weapons_owner_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapons
    ADD CONSTRAINT weapons_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES personnel.employees(id);


--
-- Name: weapons weapons_unit_id_fkey; Type: FK CONSTRAINT; Schema: personnel; Owner: -
--

ALTER TABLE ONLY personnel.weapons
    ADD CONSTRAINT weapons_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES core.units(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict u4WYajMkdQyWOncwjkSbc6OhuGPq8U8wXMb7yqLgivfx2Nuir2hWj2YDBJ2PBD0

