-- ToGo Leader v1. Additive authenticated admin APIs and dispatcher role gates.
CREATE OR REPLACE FUNCTION public.leader_context() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE c jsonb:=togo_intake_private.identity(); r text;
BEGIN SELECT role INTO r FROM togo_intake_private.admin_subjects WHERE subject=c->>'sub';
IF r IS NULL OR r NOT IN('operations','accounting')THEN RAISE EXCEPTION 'Admin account required' USING ERRCODE='PT403';END IF;
RETURN jsonb_build_object('subject',c->>'sub','role',r,'build','leader-3-candidate-1');END $$;
CREATE OR REPLACE FUNCTION public.leader_read(section text,p_limit integer DEFAULT 50,p_offset integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE ctx jsonb:=public.leader_context();r jsonb;l integer:=least(greatest(p_limit,1),100);off integer:=greatest(p_offset,0);
BEGIN
IF section='catalog' THEN RETURN jsonb_build_object(
'companies',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.name),'[]')FROM(SELECT id,name,active FROM togo_leader.companies)x),
'couriers',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.name),'[]')FROM(SELECT id,name,active FROM togo_leader.couriers)x),
'rates',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.valid_from DESC),'[]')FROM(SELECT id,courier_id,courier_minor::text,valid_from,basis FROM togo_leader.rate_rules WHERE valid_from<=now())x),
'periods',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.starts_at DESC),'[]')FROM(SELECT id,starts_at,ends_at,closed_at FROM togo_leader.periods)x));
ELSIF section='operations' THEN
SELECT jsonb_build_object('total',(SELECT count(*)FROM togo_leader.orders),'rows',coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.created_at DESC,x.id),'[]'))INTO r FROM(
SELECT o.id,o.company_id,o.company_order_ref,o.outcome,o.version,o.delivery_on,o.created_at,o.package_count,o.product_minor::text,o.delivery_minor::text,c.name company_name,oc.customer_name,oc.phone,oc.address,oc.lat,oc.lng,
(SELECT jsonb_build_object('id',a.id,'courier_id',a.courier_id,'status',a.status)FROM togo_leader.assignments a WHERE a.order_id=o.id ORDER BY a.created_at DESC LIMIT 1) assignment,
(SELECT t.mode FROM togo_leader.order_payment_terms t WHERE t.order_id=o.id)payment_mode
FROM togo_leader.orders o JOIN togo_leader.companies c ON c.id=o.company_id LEFT JOIN togo_leader.order_contacts oc ON oc.order_id=o.id ORDER BY o.created_at DESC,o.id LIMIT l OFFSET off)x;RETURN r;
ELSIF section IN('reports','accounts','close_preview')THEN
IF ctx->>'role'<>'accounting'THEN RAISE EXCEPTION 'Accounting role required' USING ERRCODE='PT403';END IF;
IF section='reports'THEN
SELECT jsonb_build_object('total',(SELECT count(*)FROM togo_leader.inbox WHERE source='rider'AND state='pending'),'rows',coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.received_at,x.id),'[]'))INTO r FROM(
SELECT i.id,i.payload,i.state,i.received_at,o.id order_id,o.company_order_ref,o.version,o.product_minor::text,o.delivery_minor::text,cu.name courier_name,co.name company_name,t.mode
FROM togo_leader.inbox i LEFT JOIN togo_leader.assignments a ON a.id=(i.payload->>'assignment_id')::uuid LEFT JOIN togo_leader.orders o ON o.id=a.order_id LEFT JOIN togo_leader.couriers cu ON cu.id=a.courier_id LEFT JOIN togo_leader.companies co ON co.id=o.company_id LEFT JOIN togo_leader.order_payment_terms t ON t.order_id=o.id
WHERE i.source='rider'AND i.state='pending' ORDER BY i.received_at,i.id LIMIT l OFFSET off)x;RETURN r;
ELSIF section='accounts'THEN RETURN jsonb_build_object(
'couriers',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.name),'[]')FROM(SELECT c.id,c.name,coalesce(b.cash_custody_minor,0)::text cash_custody_minor,coalesce(b.payable_minor,0)::text payable_minor,coalesce(b.net_remittance_minor,0)::text net_remittance_minor FROM togo_leader.couriers c LEFT JOIN togo_leader.courier_actual_balances b ON b.courier_id=c.id)x),
'companies',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.name),'[]')FROM(SELECT c.id,c.name,coalesce(b.company_payable_minor,0)::text company_payable_minor,coalesce(b.delivery_receivable_minor,0)::text delivery_receivable_minor FROM togo_leader.companies c LEFT JOIN togo_leader.company_settlement_balances b ON b.company_id=c.id)x));
ELSE RETURN jsonb_build_object('periods',public.admin_period_archives(NULL),'pending_reports',(SELECT count(*)FROM togo_leader.inbox WHERE state='pending'),'unbalanced_journals',(SELECT count(*)FROM(SELECT j.id FROM togo_leader.journals j JOIN togo_leader.journal_lines l ON l.journal_id=j.id GROUP BY j.id HAVING sum(l.debit_minor)<>sum(l.credit_minor))x),'balances',(SELECT coalesce(jsonb_agg(to_jsonb(x)ORDER BY x.code),'[]')FROM(SELECT a.code,a.kind,togo_leader.account_net(a.id)::text balance_minor FROM togo_leader.accounts a WHERE togo_leader.account_net(a.id)<>0)x));END IF;
ELSE RAISE EXCEPTION 'Unknown section' USING ERRCODE='PT404';END IF;
END $$;
CREATE OR REPLACE FUNCTION public.admin_engine(fn text,payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE ctx jsonb:=public.leader_context();p jsonb;r jsonb;
BEGIN
IF jsonb_typeof(payload)IS DISTINCT FROM 'object'THEN RAISE EXCEPTION 'Object payload required' USING ERRCODE='PT400';END IF;
IF fn IN('commit_reviewed_import','confirm_order_payment','prepare_order','assign_reviewed_order','create_return_service','confirm_return_service_stage')THEN NULL;
ELSIF fn IN('review_rider_report','settle_cash','settle_company_receivable','review_return_service_report','record_return_custody_incident','resolve_return_custody_incident','settle_return_custody_claim','record_company_refund_advance','close_return_no_pickup','create_setup_record','claim_recovery')THEN
IF ctx->>'role'<>'accounting'THEN RAISE EXCEPTION 'Accounting role required' USING ERRCODE='PT403';END IF;
ELSE RAISE EXCEPTION 'Function not in admin allowlist' USING ERRCODE='PT403';END IF;
p:=payload||jsonb_build_object('actor','admin:'||(ctx->>'subject'));
EXECUTE format('SELECT to_jsonb(togo_leader.%I($1))',fn)INTO r USING p;RETURN r;
END $$;
-- Review + outcome is one transaction. Never accepts a caller-made outcome or collected amount.
CREATE OR REPLACE FUNCTION public.leader_review_report(p_request jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE ctx jsonb:=public.leader_context();i togo_leader.inbox%ROWTYPE;a togo_leader.assignments%ROWTYPE;o togo_leader.orders%ROWTYPE;p jsonb;outcome uuid;per uuid;d uuid;v_accepted boolean;v_extra jsonb;
BEGIN
IF ctx->>'role'<>'accounting'THEN RAISE EXCEPTION 'Accounting role required' USING ERRCODE='PT403';END IF;
IF jsonb_typeof(p_request)IS DISTINCT FROM 'object'OR coalesce(btrim(p_request->>'request_key'),'')=''OR coalesce(btrim(p_request->>'review_reason'),'')=''THEN RAISE EXCEPTION 'Review reason and request key required' USING ERRCODE='PT400';END IF;
v_accepted:=(p_request->>'accepted')::boolean;IF v_accepted IS NULL THEN RAISE EXCEPTION 'Explicit review required' USING ERRCODE='PT400';END IF;
SELECT *INTO STRICT i FROM togo_leader.inbox WHERE id=(p_request->>'inbox_id')::uuid AND source='rider' FOR UPDATE;
-- Stable canonical review payload makes an identical retry replayable; changed intent conflicts.
p:=jsonb_build_object('request_key',p_request->>'request_key','actor','admin:'||(ctx->>'subject'),'evidence',p_request->>'review_reason','effective_at',i.received_at,'inbox_id',i.id,'accepted',v_accepted,'review_reason',p_request->>'review_reason','review_inputs',p_request);
IF i.state<>'pending'THEN
SELECT rr.decision_id INTO d FROM togo_leader.report_reviews rr JOIN togo_leader.rule_decisions rd ON rd.id=rr.decision_id WHERE rr.inbox_id=i.id AND rd.request_key=p_request->>'request_key'AND rr.accepted=v_accepted AND rr.review_reason=p_request->>'review_reason'AND rd.actor='admin:'||(ctx->>'subject')AND rd.request->'review_inputs'=p_request;
IF d IS NULL THEN RAISE EXCEPTION 'Report already reviewed or retry conflict' USING ERRCODE='PT409';END IF;
RETURN jsonb_build_object('id',d,'state',i.state,'replayed',true);END IF;
IF v_accepted THEN
SELECT *INTO STRICT a FROM togo_leader.assignments WHERE id=(i.payload->>'assignment_id')::uuid;
SELECT *INTO STRICT o FROM togo_leader.orders WHERE id=a.order_id FOR UPDATE;
IF o.version IS DISTINCT FROM (p_request->>'expected_version')::integer THEN RAISE EXCEPTION 'Stale order version' USING ERRCODE='PT409';END IF;
SELECT id INTO per FROM togo_leader.periods WHERE closed_at IS NULL AND i.received_at>=starts_at AND i.received_at<ends_at;
IF per IS NULL THEN RAISE EXCEPTION 'Report period unavailable or closed' USING ERRCODE='PT409';END IF;
v_extra:=jsonb_build_object('customer_contact_verified',(p_request->>'customer_contact_verified')::boolean,'no_departure_verified',(p_request->>'no_departure_verified')::boolean,'distance_verified',(p_request->>'distance_verified')::boolean,'distance_evidence',p_request->>'distance_evidence','distance_m',p_request->>'distance_m','company_fee_approved',(p_request->>'company_fee_approved')::boolean,'company_fee_evidence',p_request->>'company_fee_evidence','company_service_due_minor',p_request->>'company_service_due_minor');
outcome:=togo_leader.approve_delivery_outcome(v_extra||jsonb_build_object('request_key',(p_request->>'request_key')||':outcome','actor',p->>'actor','evidence',p->>'evidence','effective_at',i.received_at,'assignment_id',a.id,'order_id',o.id,'kind',i.payload->'payload'->>'kind','actual_collection_minor',i.payload->'payload'->>'collected_minor','expected_version',o.version,'period_id',per));p:=p||jsonb_build_object('outcome_decision_id',outcome);
END IF;
d:=togo_leader.review_rider_report(p);RETURN jsonb_build_object('id',d,'state',CASE WHEN v_accepted THEN 'accepted'ELSE 'rejected'END,'replayed',false);
END $$;
REVOKE ALL ON FUNCTION public.leader_context(),public.leader_read(text,integer,integer),public.leader_review_report(jsonb)FROM PUBLIC,anonymous;
GRANT EXECUTE ON FUNCTION public.leader_context(),public.leader_read(text,integer,integer),public.leader_review_report(jsonb)TO authenticated;
