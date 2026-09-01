-- =============================================================================
-- 0032 — bank.book.record
-- =============================================================================
-- Writing a bank entry was, until now, reachable by anyone who could *view* the
-- bank book: there was no write permission for it in the catalogue. Spec §6 and
-- §47 want the check to name the thing being done, so this adds the code and
-- grants it exactly where the seed's own matrix would have put it — every role
-- that already holds the rest of the bank module.
--
-- Rollback: delete from public.role_permissions where permission_code = 'bank.book.record';
--           delete from public.permissions where code = 'bank.book.record';
-- =============================================================================

insert into public.permissions (code, module, description, is_sensitive)
values ('bank.book.record', 'bank', 'Record bank receipts and payments', false)
on conflict (code) do nothing;

-- ACCOUNTS holds the whole bank module; DEALER_OWNER holds everything bar
-- platform administration. Mirroring seed.sql rather than inventing a new rule.
insert into public.role_permissions (role_id, permission_code)
select r.id, 'bank.book.record'
  from public.roles r
 where r.is_system
   and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;
