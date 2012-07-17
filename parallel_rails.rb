

# okay, we knows what you're thinking, if you are running this how do you
# make sure that all records are processed? well, you run this after the
# new logic is working in production, so new records do not require the
# fix (or at least, that's how it worked for me)



# WORKING SOLUTION -- SEE README
def self.update_invoices
  # parallel note: first attempted to let parallel gem manage array
  # of arrays, where number of arrays > processes, but gem segment
  # faulted on loading array after completing one ('broken pipe')
  #
  # fix fee invoices
  # note +1 on batch size to ensure number of batches
  # equals number of processes (no remainders array)
  sacks = []
  ids = Invoice.service_fee_eq(1).map(&:id)
  number_records = ids.size
  process_count = 4
  batch_size = (number_records/process_count).to_i + 1
  ids.each_slice(batch_size) { |sack| sacks << sack}
  Parallel.each(sacks, :in_processes => process_count) do |sack| 
    ActiveRecord::Base.connection.reconnect!
    sack.each do |invoice_id|
      Invoice.find(invoice_id).fix_service_fee
    end
  end
  #
  # naive approach worked fine for fees, but there are millions
  # of regular invoices (creating batch arrays kills memory)
  # how could we leverage activerecord cursor management?
  #
  # fix non-fee invoices
  # avoid using 'count' of table, as last key will
  # often be greater than row count
  ActiveRecord::Base.connection.reconnect!
  last_id = Invoice.last.id
  batch_count = 4
  batch_size = (last_id/batch_count).to_i
  batch_1 = [] << 1 << batch_size
  batch_2 = [] << (batch_size + 1) << (2*batch_size)
  batch_3 = [] << (2*batch_size + 1) << (3*batch_size)
  batch_4 = [] << (3*batch_size + 1) << last_id
  sacks = [] << batch_1 << batch_2 << batch_3 << batch_4
  Parallel.each(sacks, :in_processes => 4) do |sack| 
    ActiveRecord::Base.connection.reconnect!
    start_key = sack[0]
    stop_key = sack[1]
    Invoice.service_fee_eq(0).
            id_gte(start_key).
            id_lte(stop_key).
            find_each do |invoice|
              invoice.fix_regular_invoice
            end
  end
end



# FAILURE #1 -- SIMPLE SOLUTION, TOO SLOW
def self.update_invoices
  # migration - fix invoices (via application console), network
  # overhead makes naive approach slow, try parallel
  Invoice.service_fee_eq(1).find_each {
    |invoice| invoice.fix_service_fee
  }
  Invoice.service_fee_eq(0).find_each {
    |invoice| invoice.fix_regular_invoice
  }
end



# FAILURE #2 -- BROKEN PIPE AFTER FIRST SERIES OF BATCHES?
# create array of 100-record batches, and let Parallel
# iterate through the batches... admittedly dumb
def self.update_invoices
  # fix fee invoices
  sacks = []
  ids = Invoice.service_fee_eq(1).map(&:id)
  ids.each_slice(100) { |sack| sacks << sack}
  Parallel.each(sacks, :in_processes => 4) do |sack| 
    ActiveRecord::Base.connection.reconnect!
    sack.each do |invoice_id|
      Invoice.find(invoice_id).fix_service_fee
    end
  end
  # fix non-fee invoices
  sacks = []
  ids = Invoice.service_fee_eq(0).map(&:id)
  ids.each_slice(100) { |sack| sacks << sack}
  Parallel.each(sacks, :in_processes => 4) do |sack| 
    ActiveRecord::Base.connection.reconnect!
    sack.each do |invoice_id|
      Invoice.find(invoice_id).fix_regular_invoice
    end
  end
end



# FAILURE #3 -- USES TOO MUCH MEMORY
def self.update_invoices
  # fix fee invoices
  sacks = []
  ids = Invoice.service_fee_eq(1).map(&:id)
  number_records = ids.size
  process_count = 4
  batch_size = (number_records/process_count) + 1
  ids.each_slice(batch_size) { |sack| sacks << sack}
  Parallel.each(sacks, :in_processes => process_count) do |sack| 
    ActiveRecord::Base.connection.reconnect!
    sack.each do |invoice_id|
      Invoice.find(invoice_id).fix_service_fee
    end
  end
  # fix non-fee invoices
  sacks = []
  ids = Invoice.service_fee_eq(0).map(&:id)
  number_records = ids.size
  process_count = 4
  batch_size = (number_records/process_count) + 1
  ids.each_slice(batch_size) { |sack| sacks << sack}
  Parallel.each(sacks, :in_processes => 4) do |sack| 
    ActiveRecord::Base.connection.reconnect!
    sack.each do |invoice_id|
      Invoice.find(invoice_id).fix_regular_invoice
    end
  end
end



