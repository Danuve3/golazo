// Conexión con el ranking público (Supabase).
// Rellena estos dos valores con los de tu proyecto: Project Settings → API.
// La clave "publishable"/"anon" es pública por diseño: la base de datos solo
// permite las operaciones que define supabase/schema.sql.
// Si los dejas vacíos, el juego funciona igual pero sin ranking ni nombres.
window.GOLAZO_CONFIG = {
  supabaseUrl: '',
  supabaseAnonKey: ''
};
