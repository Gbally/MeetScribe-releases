from .cli import main

if __name__ == "__main__":  # not when multiprocessing re-imports it in a helper process
    main()
