# Fair SQLite busy handler: равномерный микро-retry вместо эскалирующего
# дефолта.
#
# Дефолтный busy-хендлер (sqlite3_busy_timeout) спит с эскалацией
# 1→2→5→10→15→20→25…→100ms и НЕсправедлив: при N конкурирующих писателях
# спящий просыпается, проигрывает гонку за лок только что проснувшемуся
# и засыпает ещё дольше — хвосты в сотни миллисекунд при микросекундных
# транзакциях (наблюдали p99=340ms при среднем времени транзакции <1ms:
# 1+2+5+10+15+20+25+25 ≈ ступени эскалации).
#
# Равномерные 500µs дают честный round-robin между писателями без
# эскалации. Хендлер спит в C (LibC.usleep), блокируя event-loop — это
# безопасно ровно до тех пор, пока держатель write-lock'а живёт в ДРУГОМ
# процессе (fork-воркеры) или в единственной writer-фибере — см.
# Campfire::WriteQueue в once-campfire-crails: в процессе за write-lock
# никто не конкурирует, заморозка цикла не лайвлокит держателя.
#
# 40 000 повторов × 500µs = 20 секунд потолка, как у типичного
# busy_timeout, затем SQLITE_BUSY уходит в retry вызывающего.

lib LibSQLite3Busy
  fun handler = sqlite3_busy_handler(db : Void*,
    cb : (Void*, Int32 -> Int32), arg : Void*) : Int32

  fun usleep(useconds : UInt32) : Int32
end

fun crails_sqlite_fair_busy(arg : Void*, count : Int32) : Int32
  LibSQLite3Busy.usleep(500_u32)
  count < 40_000 ? 1 : 0
end

module ActiveRecord
  module FairBusy
    # Подменяет дефолтный (эскалирующий) busy-хендлер соединения.
    def self.install(conn : SQLite3::Connection) : Nil
      LibSQLite3Busy.handler(conn.to_unsafe.as(Pointer(Void)),
        ->crails_sqlite_fair_busy(Void*, Int32), nil)
    end
  end
end
