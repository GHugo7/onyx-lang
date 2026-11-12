// A pool of workers processing jobs in parallel with `fork` and channels.

struct Job {
    id: int
    size: int
}

struct Result {
    job: int
    worker: int
    millis: int
}

fn worker(id: int, jobs: chan<Job>, results: chan<Result>) {
    for job in jobs {
        var start = now()
        sleep(job.size * 10)    // pretend to work
        results <- Result{job: job.id, worker: id, millis: now() - start}
    }
}

fn main() {
    var jobs = chan<Job>()
    var results = chan<Result>()
    var job_count = 8

    // Start three workers. Each one waits for jobs on the same channel.
    for id in 1..4 {
        fork { worker(id, jobs, results) }
    }

    // Send the jobs from another task, then close the channel so the
    // workers' `for` loops end.
    fork {
        for i in 0..job_count {
            jobs <- Job{id: i, size: 1 + i % 3}
        }
        jobs.close()
    }

    var start = now()
    var per_worker: map<int, int> = {}
    for i in 0..job_count {
        var r = <-results
        per_worker[r.worker] = (per_worker.get(r.worker) or 0) + 1
        print("job {r.job} finished by worker {r.worker} in ~{r.millis / 10 * 10}ms")
    }
    print("all {job_count} jobs done; every worker took part: {per_worker.len() == 3}")
    print("faster than doing them one by one: {now() - start < 160}")
}
