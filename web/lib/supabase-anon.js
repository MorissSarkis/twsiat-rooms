import { createClient } from '@supabase/supabase-js';
// Server-side client with the public key only (no user session). All checks happen in the database.
export const supabaseAnon = () => createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
