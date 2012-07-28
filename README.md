## Parallel Rails Updating
### Orientation

*Disclaimer: I may never use github the way it is intended. I have plans to share gems and projects that may involve collaboration, but I suspect most of my "projects" will be little more than code showcases.*


Michael Grosser posted a [cool application](http://grosser.it/2012/07/15/return-values-from-fork-fork_and_return/) of the Parallel gem (see blog _My Pragmatic life — a blog by Michael Grosser_ for more cool hacks). Here is the code posted...

    # http://grosser.it/2012/07/15/return-values-from-fork-fork_and_return/
    # forking method definition
    def fork_and_return(&block)
      require 'parallel'
      Parallel.map([0], &block).first
    end

    # forking method in practice
    result = fork_and_return do
      require 'some_lib_with_side_effects'
      leak_some_memory
      get_stuff_done
    end
    puts result

I suspect this is not how most developers would use Parallel, because I believe systems naturally evolve to include queuing (e.g. resque) -- which is the natural place to stow something like this... And this method will _spam a lot of threads_ (sorry, Michael).

Where I think developers are drawn into the thickets of Parallel is trying to make significant data store updates run faster (by running entity updates in parallel).

Anyone approaching Parallel has to get it working in a basic sense first, e.g. create several processes and make sure printed record ids (or numbers from process-specified ranges) are *put* interspersed. I am not sure that is instructive enough to include a code run here, because examples abound online.

Instead, I will provide an example of what works... In the code file, I will show various examples of *what does not work*. Parallel has notorious bugs. When you encounter a pipe error, and track it down online, you may be surprised to find it has been solved long ago, despite your troubles.

## Updating ActiveRecord Table Records

Two approaches are shown below for decreasing the duration of mass data updates. Both approaches avoid letting Parallel manage batches or spawn new processes after one expires -- which seems fraught with peril.

I spent enough time on this, that I was not tempted to crawl further down the rabbit hole -- making the number of processes adjust according to the number of available processors. I had four cores in development, and it feels safer to deploy what has been exhaustively tested. Iterating over a data-store seems like something that is unusual, so it is best to consider it exceptional.

The first approach is naive [see *fix fee invoices*], and was kept for simplicity. What I observed is that attempting to create arrays of ids for large numbers of records consumed an intolerable amount of time and memory. Here there were hundreds of thousands of records, and the processing happend quickly.

The second approach was more robust [see *fix non-fee invoices*]. If there is anything ingenious here, it is that I leverage ActiveRecord to manage memory (via *find_each*).

There are many approaches to get this working, but this hack worked well. When doing something like this, I would consider any solution that finished without errors and my machine usable to be awesome (because it is easy to end up with virtually no free memory after extensive processing).

When doing something like this, try to make your code *idempotent*, e.g. running your fix multiple times on a record does no harm. It is easy to track processed record ids via Redis, if you would like the added insurance of being able to restart the job and avoid reprocessing records. Deleting a Redis set with millions of members will time out though, so it should be done in a begin..rescue statement.


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


## ActiveRecord and Primrose Path Musings

ActiveRecord is complicated. We often create our own arrays of hashes, and I have seen Rails developers fall into the trap of doing this...

    ids = array_of_hashes.map(&:id)

But hashes are not ActiveRecord objects, so keys are not converted from symbol (*field name*) to accessor method (via meta-programming). This code would throw an error, or worse, assign an array of *object IDs*.

Unfortunately, there does not seem to be a way to make it work, e.g. this does *not* work...

    ids = array_of_hashes.map(&:fetch(:id))

Just another curiosity.

